// Package main — точка входа backend-сервиса Craft WMS.
//
// P0-02: каркас HTTP-сервиса — конфиг из окружения, структурированный логгер,
// chi-роутер и graceful shutdown.
// P0-03: подключение к PostgreSQL (пул pgx) + readiness-проба /ready.
// Бизнес-логики пока нет — это «розетка», в которую дальше подключаются auth и операции.
package main

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"craftwms/internal/auth"
	"craftwms/internal/config"
	"craftwms/internal/handler"
	appmw "craftwms/internal/middleware"
	"craftwms/internal/observability"
	"craftwms/internal/repository"
	"craftwms/internal/service"
	"craftwms/internal/trueapi"
)

// shutdownTimeout — сколько ждём завершения текущих запросов при мягкой остановке.
const shutdownTimeout = 10 * time.Second

func main() {
	// 1. Конфиг из окружения — один бинарь для dev/prod, меняется только окружение.
	cfg := config.Load()

	// 2. Отправка ошибок в Bugsink (ADHOC-42): без SENTRY_DSN выключена. Включается до
	//    логгера — тот на каждой ошибке спрашивает, есть ли куда отправлять.
	monitored, monErr := observability.Init(observability.Options{
		DSN:         cfg.SentryDSN,
		Environment: cfg.SentryEnvironment,
		Release:     cfg.SentryRelease,
	})

	// 3. Общий структурированный JSON-логгер (пишет в stdout — стандарт для контейнеров).
	//    Ошибки журнала он же отправляет в Bugsink — с пользователем запроса из контекста.
	log := newLogger(cfg.LogLevel)
	slog.SetDefault(log)
	if monErr != nil {
		// Неверный DSN не повод не работать: склад важнее уведомлений.
		log.Warn("error reporting disabled: bad SENTRY_DSN", "error", monErr)
	} else if monitored {
		log.Info("error reporting enabled", "environment", cfg.SentryEnvironment)
	}
	defer observability.Flush(2 * time.Second)

	// 3. Пул соединений к БД. Если DATABASE_URL пуст — стартуем без БД (удобно для локальной
	//    отладки каркаса); /ready в этом случае вернёт 503.
	var pool *pgxpool.Pool
	if cfg.DatabaseURL != "" {
		p, err := repository.NewPool(context.Background(), cfg.DatabaseURL)
		if err != nil {
			log.Error("cannot init database pool", "error", err)
			os.Exit(1)
		}
		pool = p
		defer pool.Close()

		// Ранняя проверка доступности БД. Не роняем сервис при неудаче: процесс живой,
		// а неготовность видно по /ready — так контейнер не флапает из-за кратких сбоев БД.
		pingCtx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		if err := pool.Ping(pingCtx); err != nil {
			log.Warn("database unreachable at startup", "error", err)
		} else {
			log.Info("database connected")
		}
		cancel()
	} else {
		log.Warn("DATABASE_URL is empty — starting without database")
	}

	// handler.Pinger — интерфейс; передаём nil-интерфейс, если пула нет (иначе /ready паникнет).
	var pinger handler.Pinger
	if pool != nil {
		pinger = pool
	}

	// 4. Менеджер JWT-токенов. Секрет — из env; если пуст, генерируем эфемерный (токены не
	//    переживут рестарт, но каркас запустится — удобно для локальной отладки).
	secret := cfg.JWTSecret
	if secret == "" {
		secret = randomSecret()
		log.Warn("JWT_SECRET is empty — using ephemeral secret (tokens won't survive restart)")
	}
	tokens := auth.NewTokenManager(secret, cfg.AccessTTL, cfg.RefreshTTL)

	// Сервисы доступны только при наличии БД (нужны репозитории). Без неё структура остаётся
	// нулевой, и роутер просто не регистрирует их маршруты.
	var svc handler.Services
	if pool != nil {
		users := repository.NewUserRepository(pool)
		svc.Auth = service.NewAuthService(users, tokens)
		// Права должности — для проверок по праву на каждой ручке (ADHOC-49).
		svc.Rights = users
		// Пользователи и должности в портале (ADHOC-49).
		svc.Users = service.NewUserAdminService(repository.NewUserAdminRepository(pool))
		// Репозитории справочников: переиспользуются импортом (запись) и каталогом (чтение).
		groups := repository.NewNomenclatureGroupRepository(pool)
		suppliers := repository.NewSupplierRepository(pool)
		goods := repository.NewGoodsRepository(pool)
		cells := repository.NewCellRepository(pool)
		stock := repository.NewStockRepository(pool)
		// Импорт справочников из файлов: номенклатура (группы+поставщики+товары) и ячейки (склад+ячейки).
		svc.Import = service.NewImportService(pool, groups, suppliers, goods,
			repository.NewWarehouseRepository(pool), cells)
		// Чтение справочников (P1-06): товары/группы/поставщики/ячейки/остатки.
		svc.Catalog = service.NewCatalogService(goods, groups, suppliers, cells, stock)
		// Привязка ШК к товару и резолв по ШК (ввод остатков P-FastStart, P-FS-03).
		svc.Barcode = service.NewBarcodeService(repository.NewBarcodeRepository(pool))
		// Сессия ввода остатков (P-FastStart, P-FS-04): старт/checkpoint/финал → stock.
		svc.StockEntry = service.NewStockEntryService(repository.NewStockEntryRepository(pool))
		// PDF этикеток ячеек и карточек на стойку (ADHOC-57): геометрия rack_labels.
		svc.Label = service.NewLabelService(repository.NewWarehouseRepository(pool), cells)
		// Страница «Ячейки» портала (ADHOC-57): стеллажи, галочки этикеток, выгрузка в .xlsx.
		svc.CellSetup = service.NewCellSetupService(pool, repository.NewWarehouseRepository(pool), cells)
		// Excel-отчёт «ввод остатков» по закрытой сессии (P-FastStart, P-FS-08).
		svc.Document = service.NewDocumentService(repository.NewReportDocumentRepository(pool))
		// Батч операций офлайн-очереди устройства (P2-05): дедуп по operation_id.
		svc.Operations = service.NewOperationsService(repository.NewOperationsRepository(pool))

		// Приёмка и грузовые единицы (P4-02, P4-03): документ, строка сканом, оприходование.
		svc.Receipt = service.NewReceiptService(repository.NewReceiptRepository(pool), cells)
		svc.LoadUnit = service.NewLoadUnitService(repository.NewLoadUnitRepository(pool))
		svc.Task = service.NewTaskService(repository.NewTaskRepository(pool))
		svc.Stocktake = service.NewStocktakeService(repository.NewStocktakeRepository(pool))
		// История перемещений на ТСД (ADHOC-28).
		svc.MovementHistory = service.NewMovementHistoryService(repository.NewMovementHistoryRepository(pool))
		// Справочник внутренних складов для пометки брака на ТСД (P6-07-1).
		svc.InternalWarehouse = service.NewInternalWarehouseService(repository.NewInternalWarehouseRepository(pool))
		svc.Problem = service.NewProblemService(repository.NewProblemRepository(pool))
		// Справочник причин проблем и вариантов решения (ADHOC-55).
		svc.ProblemReason = service.NewProblemReasonService(repository.NewProblemReasonRepository(pool))
		svc.ProblemPhoto = service.NewProblemPhotoService(repository.NewProblemPhotoRepository(pool))
		// Загрузка «Реестра» 1С на сборку в портале (P8-02): разбор P9-01, сверка с загруженным.
		svc.Picking = service.NewPickingLoadService(service.NewPickingRegistryService(goods),
			repository.NewPickingRepository(pool), repository.NewWarehouseRepository(pool))
		// Сборка на ТСД (P9-03, P9-04): заказ с подбором, взять, короб отгрузки, «не хватает».
		svc.PickingTask = service.NewPickingTaskService(repository.NewPickingRepository(pool))
		// Просмотр содержимого ячеек и коробов на ТСД (P5-05).
		svc.Contents = service.NewContentsService(repository.NewContentsRepository(pool))
		// Версии данных по областям — заголовок каждого ответа API (ADHOC-60).
		svc.DataVersions = repository.NewDataVersionRepository(pool)
	} else {
		log.Warn("no database — auth, import and catalog endpoints disabled")
	}

	// Честный знак (CZ-02): БД не нужна, только подписант на хосте. Без CZ_SIGNER_SOCKET
	// клиента нет, и ручки ЧЗ отвечают «не настроен» — локальный стек и стенд как раньше.
	var czClient *trueapi.Client
	// Хранилище марок (CZ-03) — только с БД; явный nil интерфейса, если пула нет.
	var czMarks service.CZMarks
	if pool != nil {
		czMarks = repository.NewCZMarkRepository(pool)
	}
	if cfg.CZSignerSocket != "" {
		czClient = trueapi.New(trueapi.Options{
			BaseURL:       cfg.CZAPIURL,
			Signer:        trueapi.NewSocketSigner(cfg.CZSignerSocket),
			RefreshBefore: cfg.CZRefreshBefore,
			Log:           log,
		})
		svc.CZ = service.NewCZService(czClient, czMarks).WithOwnerINN(cfg.CZOwnerINN)
		log.Info("chestny znak enabled", "api", cfg.CZAPIURL, "signer", cfg.CZSignerSocket)
		if cfg.CZOwnerINN == "" {
			log.Warn("CZ_OWNER_INN is empty — mark owner is not checked on receipt")
		}
	} else {
		// Явный nil интерфейса: *trueapi.Client(nil) внутри интерфейса не был бы nil.
		svc.CZ = service.NewCZService(nil, czMarks)
	}

	// Ошибки ТСД и портала (ADHOC-47): пересылка в проект Bugsink `app`. Без CLIENT_SENTRY_DSN
	// события приложений отбрасываются. Неверный DSN — работаем без пересылки, как с SENTRY_DSN.
	if relay, err := observability.NewRelay(cfg.ClientSentryDSN); err != nil {
		log.Warn("client error relay disabled: bad CLIENT_SENTRY_DSN", "error", err)
	} else if relay != nil {
		// Только непустой: *Relay(nil) внутри интерфейса nil не был бы.
		svc.ClientErrors = relay
		log.Info("client error relay enabled")
	}

	// 5. HTTP-сервер с собранным роутером транспортного слоя.
	srv := &http.Server{
		Addr:              ":" + cfg.AppPort,
		Handler:           handler.NewRouter(log, pinger, tokens, svc),
		ReadHeaderTimeout: 5 * time.Second, // защита от медленных клиентов (Slowloris)
	}

	// 6. Контекст, отменяемый по SIGINT/SIGTERM — сигнал начать мягкую остановку
	//    (SIGTERM прилетает при `docker compose down` / редеплое).
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	// Фоновое обновление токена ЧЗ: первый токен — сразу при старте, дальше до истечения.
	if czClient != nil {
		go czClient.Run(ctx)
	}

	// 7. Запускаем приём соединений в отдельной горутине, чтобы main мог ждать сигнал.
	go func() {
		log.Info("backend listening", "addr", srv.Addr, "log_level", cfg.LogLevel.String())
		// ErrServerClosed — штатное завершение после Shutdown, ошибкой не считаем.
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Error("server failed", "error", err)
			stop() // будим main для завершения процесса
		}
	}()

	// 8. Блокируемся до сигнала остановки.
	<-ctx.Done()
	log.Info("shutdown signal received, draining connections")

	// 9. Graceful shutdown: перестаём принимать новые соединения и даём текущим запросам
	//    до-обработаться в пределах таймаута. Зачем: не рвать операцию на полуслове —
	//    в WMS это критично для консистентности остатков. Пул БД закроется по defer.
	shutdownCtx, cancel := context.WithTimeout(context.Background(), shutdownTimeout)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		log.Error("graceful shutdown failed", "error", err)
		os.Exit(1)
	}
	log.Info("server stopped cleanly")
}

// newLogger собирает JSON-логгер slog с заданным уровнем.
//
// Поверх JSON — обработчик Bugsink (ADHOC-42): записи уровня error уходят и событием.
func newLogger(level slog.Level) *slog.Logger {
	json := slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: level})
	return slog.New(observability.NewHandler(json, requestUser))
}

// requestUser — пользователь запроса для события Bugsink: его кладёт в контекст middleware
// аутентификации.
func requestUser(ctx context.Context) (id, role string, ok bool) {
	id, ok = appmw.UserIDFromContext(ctx)
	return id, appmw.RoleFromContext(ctx), ok
}

// randomSecret генерирует случайный секрет подписи JWT (fallback, если JWT_SECRET не задан).
func randomSecret() string {
	b := make([]byte, 32)
	_, _ = rand.Read(b)
	return base64.StdEncoding.EncodeToString(b)
}
