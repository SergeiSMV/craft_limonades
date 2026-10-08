package handler

import (
	"log/slog"
	"net"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"
	chimw "github.com/go-chi/chi/v5/middleware"
	"github.com/go-chi/httprate"

	"craftwms/internal/auth"
	appmw "craftwms/internal/middleware"
	"craftwms/internal/model"
	"craftwms/internal/service"
)

// Services — прикладные сервисы, которые роутер раздаёт хендлерам.
//
// Структура, а не список аргументов: сервисов уже десяток, и позиционный вызов заставлял
// каждое место сборки перечислять «nil, nil, nil, …» до нужного места. Такой вызов не читается
// и, что хуже, молча переживает перестановку двух сервисов одного типа — компилятор её
// не заметит, а роутер раздаст хендлерам чужие зависимости. Именованные поля это исключают.
//
// Любое поле может быть nil (нет БД, урезанная сборка в тесте) — тогда его маршруты
// не регистрируются вовсе, а не падают при первом запросе.
type Services struct {
	Auth       *service.AuthService
	Import     *service.ImportService
	Catalog    *service.CatalogService
	Barcode    *service.BarcodeService
	StockEntry *service.StockEntryService
	Label      *service.LabelService
	Document   *service.DocumentService
	Operations *service.OperationsService
	Receipt    *service.ReceiptService
	LoadUnit   *service.LoadUnitService
	Task       *service.TaskService
	Contents   *service.ContentsService
}

// NewRouter собирает HTTP-роутер сервиса: общие middleware + маршруты.
//
// Что: единая точка сборки транспортного слоя.
// Зачем: сюда по мере роста подключаются все будущие ручки (справочники, операции).
// Как: chi-роутер с цепочкой middleware; прикладные ручки — под /api/v1, пробы — на корне.
// db (Pinger) может быть nil → /ready ответит 503.
func NewRouter(log *slog.Logger, db Pinger, tokens *auth.TokenManager, svc Services) http.Handler {
	r := chi.NewRouter()

	// Общие middleware для всех маршрутов:
	r.Use(chimw.RequestID)          // уникальный ID запроса — для трассировки в логах
	r.Use(chimw.Recoverer)          // перехват паник → 500 вместо падения процесса
	r.Use(appmw.RequestLogger(log)) // структурированное логирование каждого запроса

	// Пробы состояния — на КОРНЕ, вне /api/v1: это инфра-эндпоинты, а не публичный API.
	// /health дёргает docker-healthcheck напрямую к контейнеру; корень (/) при этом свободен
	// под статику веб-портала (см. ADR-0015).
	health := NewHealthHandler(db)
	r.Get("/health", health.Health) // liveness: процесс жив
	r.Get("/ready", health.Ready)   // readiness: БД доступна

	// Прикладной API — под версионированным префиксом /api/v1 (ADR-0015).
	// Зачем: портал занимает корень домена, API уезжает в свой неймспейс (один origin, без CORS),
	// а версия в пути даёт запас на эволюцию без ломки клиентов.
	r.Route("/api/v1", func(r chi.Router) {
		// Аутентификация (только если есть БД).
		if svc.Auth != nil {
			authH := NewAuthHandler(svc.Auth)

			// Публичные auth-роуты с rate limit — защита от перебора секрета бейджа.
			// Ключ — реальный IP клиента (X-Real-IP от nginx), а не RemoteAddr: иначе за прокси
			// все устройства делили бы один лимит.
			r.Group(func(r chi.Router) {
				r.Use(httprate.LimitBy(10, time.Minute, clientIPKey))
				r.Post("/auth/login", authH.Login)                  // работник — по бейджу
				r.Post("/auth/login/password", authH.LoginPassword) // admin/менеджер — по логину/паролю
				r.Post("/auth/refresh", authH.Refresh)
			})

			// Защищённые роуты — требуют валидный access-токен.
			r.Group(func(r chi.Router) {
				r.Use(appmw.Authenticator(tokens))
				r.Get("/auth/me", authH.Me)
			})
		}

		// Импорт справочников — только admin (загрузка файла с телефона/web).
		if svc.Import != nil {
			importH := NewImportHandler(svc.Import)
			r.Group(func(r chi.Router) {
				r.Use(appmw.Authenticator(tokens))
				r.Use(appmw.RequireRole(model.RoleAdmin))
				r.Post("/import/goods", importH.ImportGoods) // .xls-выгрузка номенклатуры 1С
				r.Post("/import/cells", importH.ImportCells) // .xlsx-файл физических ячеек склада
			})
		}

		// PDF-этикетки ячеек (P-FastStart) — только admin (печать этикеток из портала).
		if svc.Label != nil {
			labelH := NewLabelHandler(svc.Label)
			r.Group(func(r chi.Router) {
				r.Use(appmw.Authenticator(tokens))
				r.Use(appmw.RequireRole(model.RoleAdmin))
				r.Get("/cells/labels.pdf", labelH.CellLabelsPDF)
			})
		}

		// Excel-отчёт «ввод остатков» по закрытой сессии (P-FS-08) — только admin (портал «Инвентаризация»).
		// Документы оператора (P3-02). Список общий для всех форм отчёта: «ввод остатков» сейчас,
		// «Поступление» и «Движение» — по мере появления операций в P4-P6.
		if svc.Document != nil {
			docH := NewDocumentHandler(svc.Document)
			r.Group(func(r chi.Router) {
				r.Use(appmw.Authenticator(tokens))
				r.Use(appmw.RequireRole(model.RoleAdmin))
				r.Get("/documents", docH.List)                // рабочий список: необработанные сверху
				r.Get("/documents/{id}/file.xlsx", docH.File) // скачать .xlsx (отмечает скачивание)
				r.Post("/documents/{id}/done", docH.Done)     // «Выполнено»: занесён в 1С
				r.Get("/documents/{id}/events", docH.Events)  // журнал: кто и когда что делал
			})
		}

		// Чтение справочников (товары/группы/поставщики/ячейки/остатки) — любому аутентифицированному
		// сотруднику (это кормит экраны ТСД, не только админку). Только GET, без изменений данных.
		if svc.Catalog != nil {
			catalogH := NewCatalogHandler(svc.Catalog)
			r.Group(func(r chi.Router) {
				r.Use(appmw.Authenticator(tokens))
				r.Get("/goods", catalogH.ListGoods)
				r.Get("/goods/{id}", catalogH.GetGood)
				r.Get("/nomenclature-groups", catalogH.ListGroups)
				r.Get("/suppliers", catalogH.ListSuppliers)
				r.Get("/cells", catalogH.ListCells)
				r.Get("/stock", catalogH.ListStock)
			})
		}

		// Привязка ШК и резолв товара по ШК (ввод остатков P-FastStart) — любому аутентифицированному
		// сотруднику: кладовщик привязывает ШК прямо на проходе склада (решение P-FS-03).
		if svc.Barcode != nil {
			barcodeH := NewBarcodeHandler(svc.Barcode)
			r.Group(func(r chi.Router) {
				r.Use(appmw.Authenticator(tokens))
				r.Get("/barcodes", barcodeH.List)                        // все привязки ШК (кэш устройства, P2-02)
				r.Get("/barcodes/{code}", barcodeH.GetByCode)            // товар по ШК или 404
				r.Post("/barcodes", barcodeH.Bind)                       // привязать ШК к товару
				r.Delete("/barcodes/{code}", barcodeH.Unbind)            // отвязать ошибочный ШК (P-FS-12)
				r.Get("/goods/{id}/barcodes", barcodeH.ListByGood)       // все ШК товара (P-FS-12)
				r.Post("/goods/{id}/barcode", barcodeH.GenerateInternal) // внутренний EAN-13 товару без ШК (P4-07)
			})
		}

		// Батч операций из офлайн-очереди устройства (P2-05) — сотруднику: очередь копится
		// на ТСД кладовщика. Дедуп по operation_id: повтор не применяет эффект второй раз.
		if svc.Operations != nil {
			opsH := NewOperationsHandler(svc.Operations)
			r.Group(func(r chi.Router) {
				r.Use(appmw.Authenticator(tokens))
				r.Post("/operations", opsH.Apply)
			})
		}

		// Приёмка (P4-03) — сотруднику: документ ведёт кладовщик на ТСД. Идентификаторы документа
		// и ГЕ приходят С УСТРОЙСТВА, поэтому создание идемпотентно и повтор запроса безопасен.
		// Привязка неизвестного ШК своей ручки здесь не имеет — она уже есть в /barcodes (P-FS-03)
		// и работает офлайн через очередь; второй путь к тому же эффекту дал бы два источника истины.
		if svc.Receipt != nil && svc.LoadUnit != nil {
			rcH := NewReceiptHandler(svc.Receipt, svc.LoadUnit)
			r.Group(func(r chi.Router) {
				r.Use(appmw.Authenticator(tokens))
				r.Post("/receipts", rcH.Create)             // открыть документ приёмки
				r.Get("/receipts/{id}", rcH.Get)            // шапка + строки
				r.Post("/receipts/{id}/lines", rcH.AddLine) // строка сканом (ячейка и ГЕ опциональны)
				r.Post("/receipts/{id}/post", rcH.Post)     // оприходовать: поднять остаток
				r.Post("/load-units", rcH.CreateLoadUnit)   // завести ГЕ по QR ярлыка
				r.Get("/load-units/{id}", rcH.GetLoadUnit)  // что за короб отсканировали
			})
		}

		// Задания для склада (P5-02-1) — сотруднику: пул заданий на ТСД. Взятие и отказ — только
		// со связью: кто держит задание, знает сервер, иначе двое взяли бы одно и то же.
		// Выполнение задания идёт операцией очереди putaway_submit и работает без связи.
		if svc.Task != nil {
			taskH := NewTaskHandler(svc.Task)
			r.Group(func(r chi.Router) {
				r.Use(appmw.Authenticator(tokens))
				r.Get("/tasks", taskH.Current)               // текущие: пул и свои взятые
				r.Get("/tasks/completed", taskH.Completed)   // лента «Завершённые»
				r.Get("/tasks/executors", taskH.Executors)   // варианты фильтра по исполнителю
				r.Get("/tasks/{id}", taskH.Get)              // карточка с заходами
				r.Post("/tasks/{id}/take", taskH.Take)       // взять в работу
				r.Post("/tasks/{id}/release", taskH.Release) // отказаться
			})
		}

		// Просмотр содержимого ячеек и коробов (P5-05) — сотруднику: кладовщик сканирует ячейку
		// или короб на ТСД. Только чтение. Снимок для кэша терминала сжимается: это весь склад
		// одним ответом, а повторяющиеся идентификаторы жмутся в разы.
		if svc.Contents != nil {
			contentsH := NewContentsHandler(svc.Contents)
			r.Group(func(r chi.Router) {
				r.Use(appmw.Authenticator(tokens))
				r.With(chimw.Compress(5, "application/json")).
					Get("/contents/snapshot", contentsH.Snapshot) // кэш ТСД: короба и россыпь
				r.Get("/cells/{id}/contents", contentsH.CellContents)  // что лежит в ячейке
				r.Get("/load-units/{id}/card", contentsH.LoadUnitCard) // что за короб и где
			})
		}

		// Сессия ввода остатков (P-FastStart) — тоже сотруднику: кладовщик проходит склад.
		if svc.StockEntry != nil {
			seH := NewStockEntryHandler(svc.StockEntry)
			r.Group(func(r chi.Router) {
				r.Use(appmw.Authenticator(tokens))
				r.Post("/stock-entry/sessions", seH.Start)                  // открыть сессию
				r.Post("/stock-entry/sessions/{id}/cells", seH.Checkpoint)  // checkpoint ячейки
				r.Post("/stock-entry/sessions/{id}/finalize", seH.Finalize) // финал → запись в stock
			})
		}
	})

	return r
}

// clientIPKey — ключ для rate limiting: реальный IP клиента.
// За nginx берём X-Real-IP (nginx перезаписывает его настоящим адресом, подделать нельзя);
// при прямом запуске без прокси — host из RemoteAddr.
func clientIPKey(r *http.Request) (string, error) {
	if ip := r.Header.Get("X-Real-IP"); ip != "" {
		return ip, nil
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr, nil
	}
	return host, nil
}
