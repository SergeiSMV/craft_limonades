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
	"craftwms/internal/repository"
	"craftwms/internal/service"
)

// shutdownTimeout — сколько ждём завершения текущих запросов при мягкой остановке.
const shutdownTimeout = 10 * time.Second

func main() {
	// 1. Конфиг из окружения — один бинарь для dev/prod, меняется только окружение.
	cfg := config.Load()

	// 2. Общий структурированный JSON-логгер (пишет в stdout — стандарт для контейнеров).
	log := newLogger(cfg.LogLevel)
	slog.SetDefault(log)

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

	// Сервисы доступны только при наличии БД (нужны репозитории).
	var authSvc *service.AuthService
	var importSvc *service.ImportService
	var catalogSvc *service.CatalogService
	var barcodeSvc *service.BarcodeService
	var stockEntrySvc *service.StockEntryService
	var labelSvc *service.LabelService
	var stockEntryReportSvc *service.StockEntryReportService
	var operationsSvc *service.OperationsService
	if pool != nil {
		authSvc = service.NewAuthService(repository.NewUserRepository(pool), tokens)
		// Репозитории справочников: переиспользуются импортом (запись) и каталогом (чтение).
		groups := repository.NewNomenclatureGroupRepository(pool)
		suppliers := repository.NewSupplierRepository(pool)
		goods := repository.NewGoodsRepository(pool)
		cells := repository.NewCellRepository(pool)
		stock := repository.NewStockRepository(pool)
		// Импорт справочников из файлов: номенклатура (группы+поставщики+товары) и ячейки (склад+ячейки).
		importSvc = service.NewImportService(pool, groups, suppliers, goods,
			repository.NewWarehouseRepository(pool), cells)
		// Чтение справочников (P1-06): товары/группы/поставщики/ячейки/остатки.
		catalogSvc = service.NewCatalogService(goods, groups, suppliers, cells, stock)
		// Привязка ШК к товару и резолв по ШК (ввод остатков P-FastStart, P-FS-03).
		barcodeSvc = service.NewBarcodeService(repository.NewBarcodeRepository(pool))
		// Сессия ввода остатков (P-FastStart, P-FS-04): старт/checkpoint/финал → stock.
		stockEntrySvc = service.NewStockEntryService(repository.NewStockEntryRepository(pool))
		// PDF-этикетки ячеек (P-FastStart, P-FS-05): склад по коду → ячейки → PDF.
		labelSvc = service.NewLabelService(repository.NewWarehouseRepository(pool), cells)
		// Excel-отчёт «ввод остатков» по закрытой сессии (P-FastStart, P-FS-08).
		stockEntryReportSvc = service.NewStockEntryReportService(repository.NewStockEntryRepository(pool))
		// Батч операций офлайн-очереди устройства (P2-05): дедуп по operation_id.
		operationsSvc = service.NewOperationsService(repository.NewOperationsRepository(pool))
	} else {
		log.Warn("no database — auth, import and catalog endpoints disabled")
	}

	// 5. HTTP-сервер с собранным роутером транспортного слоя.
	srv := &http.Server{
		Addr:              ":" + cfg.AppPort,
		Handler:           handler.NewRouter(log, pinger, authSvc, tokens, importSvc, catalogSvc, barcodeSvc, stockEntrySvc, labelSvc, stockEntryReportSvc, operationsSvc),
		ReadHeaderTimeout: 5 * time.Second, // защита от медленных клиентов (Slowloris)
	}

	// 6. Контекст, отменяемый по SIGINT/SIGTERM — сигнал начать мягкую остановку
	//    (SIGTERM прилетает при `docker compose down` / редеплое).
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

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
func newLogger(level slog.Level) *slog.Logger {
	return slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: level}))
}

// randomSecret генерирует случайный секрет подписи JWT (fallback, если JWT_SECRET не задан).
func randomSecret() string {
	b := make([]byte, 32)
	_, _ = rand.Read(b)
	return base64.StdEncoding.EncodeToString(b)
}
