package handler

import (
	"context"
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
	"craftwms/internal/observability"
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
	// CellSetup — страница «Ячейки» портала: стеллажи и настройки этикеток (ADHOC-57).
	CellSetup  *service.CellSetupService
	Document   *service.DocumentService
	Operations *service.OperationsService
	Receipt    *service.ReceiptService
	LoadUnit   *service.LoadUnitService
	Task       *service.TaskService
	// MovementHistory — история перемещений на ТСД (ADHOC-28).
	MovementHistory *service.MovementHistoryService
	// InternalWarehouse — справочник внутренних складов для ТСД (P6-07-1).
	InternalWarehouse *service.InternalWarehouseService
	// ProblemReason — справочник причин проблем и вариантов решения (ADHOC-55).
	ProblemReason *service.ProblemReasonService
	Contents      *service.ContentsService
	// Picking — «Сборка-отгрузка» в портале: загрузка «Реестра» 1С (P8-02).
	Picking *service.PickingLoadService
	// PickingTask — сборка на ТСД: список, заказ с подбором, взять, короб, «не хватает» (P9-04).
	PickingTask *service.PickingTaskService
	// PickingPortal — «Сборка-отгрузка» в портале: заказы на дату, детали, Excel, снятие (P8-03).
	PickingPortal *service.PickingPortalService
	// Problem — «Проблемы склада» в портале: список и решение офиса (P6-07-3).
	Problem *service.ProblemService
	// ProblemPhoto — фото к проблемам склада (ADHOC-45): загрузка с ТСД, отдача ТСД и порталу.
	ProblemPhoto *service.ProblemPhotoService
	// CZ — чтение Честного знака (CZ-02); БД не нужна, без подписанта отвечает «не настроен».
	CZ *service.CZService
	// Stocktake — пересчёт склада (P10-03): заведение, ячейки, подсчёт, закрытие.
	Stocktake *service.StocktakeService
	// ClientErrors — пересылка событий ТСД и портала в Bugsink (ADHOC-47); nil — события
	// отбрасываются, но приём остаётся: клиент не должен копить ошибки отправки.
	ClientErrors EnvelopeRelay
	// Rights — права пользователя для проверок по праву (ADHOC-49); nil — ручки с правом
	// отвечают 403 (урезанная сборка в тесте).
	Rights appmw.RightsSource
	// Users — пользователи и должности в портале (ADHOC-49).
	Users *service.UserAdminService
	// Badge — печать бейджей сотрудников на ТСД (ADHOC-65).
	Badge *service.BadgeService
	// Demo — демо-режим (ADHOC-67); nil — сервер не демо, ручек демо нет.
	Demo DemoService
	// DataVersions — версии данных по областям для заголовка каждого ответа API (ADHOC-60);
	// nil — заголовка нет (урезанная сборка в тесте).
	DataVersions appmw.VersionsSource
}

// NewRouter собирает HTTP-роутер сервиса: общие middleware + маршруты.
//
// Что: единая точка сборки транспортного слоя.
// Зачем: сюда по мере роста подключаются все будущие ручки (справочники, операции).
// Как: chi-роутер с цепочкой middleware; прикладные ручки — под /api/v1, пробы — на корне.
// db (Pinger) может быть nil → /ready ответит 503.
func NewRouter(log *slog.Logger, db Pinger, tokens *auth.TokenManager, svc Services) http.Handler {
	r := chi.NewRouter()
	// Проверки доступа (ADHOC-49/50); ставятся после Authenticator.
	// need — хоть одно из действий должности (право с точкой на конце — любое право
	// приложения: «tsd.» — любое на ТСД); needSystem — только «Администратор».
	rights := svc.Rights
	if rights == nil {
		rights = noRights{}
	}
	need := func(any ...string) func(http.Handler) http.Handler {
		return appmw.RequireAccess(rights, func(a model.Access) bool { return a.CanAny(any...) })
	}
	needSystem := appmw.RequireAccess(rights, func(a model.Access) bool { return a.System })
	documentRights := []string{
		model.RightReceiptView, model.RightReceiptDownload, model.RightReceiptPost,
		model.RightMovementView, model.RightMovementDownload, model.RightMovementPost,
		model.RightStocktakeDocView, model.RightStocktakeDocLoad, model.RightStocktakeDocPost,
		model.RightStockEntryDocView, model.RightStockEntryDocLoad, model.RightStockEntryDocPost,
	}

	// Общие middleware для всех маршрутов:
	r.Use(chimw.RequestID)          // уникальный ID запроса — для трассировки в логах
	r.Use(chimw.Recoverer)          // перехват паник → 500 вместо падения процесса
	r.Use(observability.Middleware) // запрос и паника — в Bugsink (ADHOC-42); внутри Recoverer
	r.Use(appmw.RequestLogger(log)) // структурированное логирование каждого запроса

	// Пробы состояния — на КОРНЕ, вне /api/v1: это инфра-эндпоинты, а не публичный API.
	// /health дёргает docker-healthcheck напрямую к контейнеру; корень (/) при этом свободен
	// под статику веб-портала (см. ADR-0015).
	health := NewHealthHandler(db)
	r.Get("/health", health.Health) // liveness: процесс жив
	r.Get("/ready", health.Ready)   // readiness: БД доступна

	// Приём событий ТСД и портала по протоколу Sentry (ADHOC-47): путь задаёт SDK —
	// `/api/<проект>/envelope/` по DSN, который приложение строит из адреса API. Вне /api/v1:
	// это не прикладной API, а точка приёма SDK. Частота — по IP, как у входа.
	clientErrors := NewClientErrorsHandler(svc.ClientErrors)
	r.With(httprate.LimitBy(60, time.Minute, clientIPKey)).
		Post("/api/{project}/envelope/", clientErrors.Envelope)

	// Прикладной API — под версионированным префиксом /api/v1 (ADR-0015).
	// Зачем: портал занимает корень домена, API уезжает в свой неймспейс (один origin, без CORS),
	// а версия в пути даёт запас на эволюцию без ломки клиентов.
	r.Route("/api/v1", func(r chi.Router) {
		// Версии данных — в каждом ответе API (ADHOC-60): клиент перечитывает только
		// изменившиеся области, без фонового опроса.
		if svc.DataVersions != nil {
			r.Use(appmw.DataVersions(svc.DataVersions))
		}
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

		// Демо-режим (ADHOC-67): только на демо-сервере. Вход без пароля — с тем же лимитом
		// по IP, что вход по бейджу; сброс — только «Администратор» (в демо это все).
		if svc.Demo != nil {
			demoH := NewDemoHandler(svc.Demo)
			r.Get("/demo", demoH.Status)
			r.With(httprate.LimitBy(10, time.Minute, clientIPKey)).Post("/auth/demo", demoH.Login)
			r.Group(func(r chi.Router) {
				r.Use(appmw.Authenticator(tokens))
				r.With(needSystem).Post("/demo/reset", demoH.Reset)
			})
		}

		// Импорт справочников из портала — «Номенклатура: загружать», «Ячейки: загружать».
		if svc.Import != nil {
			importH := NewImportHandler(svc.Import)
			r.Group(func(r chi.Router) {
				r.Use(appmw.Authenticator(tokens))
				r.With(need(model.RightNomenclatureImport)).
					Post("/import/goods", importH.ImportGoods) // .xls-выгрузка номенклатуры 1С
				r.With(need(model.RightCellsImport)).
					Post("/import/cells", importH.ImportCells) // .xlsx-файл физических ячеек склада
			})
		}

		// PDF этикеток ячеек и карточек на стойку (ADHOC-57) — «Ячейки: печатать этикетки».
		if svc.Label != nil {
			labelH := NewLabelHandler(svc.Label)
			r.Group(func(r chi.Router) {
				r.Use(appmw.Authenticator(tokens))
				r.Use(need(model.RightCellsLabels))
				r.Post("/cells/labels.pdf", labelH.CellLabelsPDF)
			})
		}

		// Страница «Ячейки» портала (ADHOC-57): смотреть и выгружать — с любым правом раздела,
		// менять галочки — «Ячейки: изменять настройки».
		if svc.CellSetup != nil {
			setupH := NewCellSetupHandler(svc.CellSetup)
			cellRights := []string{model.RightCellsImport, model.RightCellsLabels, model.RightCellsEdit}
			r.Group(func(r chi.Router) {
				r.Use(appmw.Authenticator(tokens))
				r.With(need(cellRights...)).Get("/cells/setup", setupH.Setup)
				r.With(need(cellRights...)).Get("/cells/export.xlsx", setupH.ExportXLSX)
				r.With(need(model.RightCellsEdit)).Patch("/cells/setup", setupH.UpdateSettings)
				// ADHOC-61: напольные ячейки «*-Н-П» ведутся вручную.
				r.With(need(model.RightCellsEdit)).Post("/cells/floor", setupH.CreateFloorCell)
				r.With(need(model.RightCellsEdit)).Patch("/cells/floor/{id}", setupH.RenameFloorCell)
				r.With(need(model.RightCellsEdit)).Delete("/cells/floor/{id}", setupH.DeleteFloorCell)
			})
		}

		// Excel-отчёт «ввод остатков» по закрытой сессии (P-FS-08). Права — по виду документа и
		// действию (ADHOC-50): маршрут пускает с правом хоть на один вид, обработчик уточняет.
		// Документы оператора (P3-02). Список общий для всех форм отчёта: «ввод остатков» сейчас,
		// «Поступление» и «Движение» — по мере появления операций в P4-P6.
		if svc.Document != nil {
			docH := NewDocumentHandler(svc.Document)
			r.Group(func(r chi.Router) {
				r.Use(appmw.Authenticator(tokens))
				r.Use(need(documentRights...))
				r.Get("/documents", docH.List)                // рабочий список: необработанные сверху
				r.Get("/documents/{id}/file.xlsx", docH.File) // скачать .xlsx (отмечает скачивание)
				r.Post("/documents/{id}/done", docH.Done)     // «Выполнено»: занесён в 1С
				r.Get("/documents/{id}/events", docH.Events)  // журнал: кто и когда что делал
			})
		}

		// Проверка мониторинга (ADHOC-43): проверочная ошибка в Bugsink. Только «Администратор» — письмо
		// уходит на каждый вызов. Сервисов не требует, поэтому вне условий выше.
		r.Group(func(r chi.Router) {
			r.Use(appmw.Authenticator(tokens))
			r.Use(needSystem)
			r.Post("/admin/monitoring/test", MonitoringTest)
		})

		// Честный знак (CZ-02) — служебное, только «Администратор»: проверка подписанта и токена, чтение марок
		// по кодам. Каждый вызов info — запрос в True API от имени организации.
		if svc.CZ != nil {
			czH := NewCZHandler(svc.CZ)
			r.Group(func(r chi.Router) {
				r.Use(appmw.Authenticator(tokens))
				r.With(needSystem).Get("/admin/cz/status", czH.Status)
				r.With(needSystem).Post("/admin/cz/info", czH.Info)
				// Признак «маркируемый» у товара (CZ-05) — «Остатки: признак ЧЗ» на ТСД.
				r.With(need(model.RightTSDStockCZMarked)).Patch("/goods/{id}/cz-marked", czH.SetGoodCZMarked)
			})
			// Скан марки или кода короба на ТСД (CZ-04) — сотруднику: кладовщик сканирует марку
			// в «Остатках» и «Номенклатуре». Только онлайн: каждый скан — запрос в True API.
			r.With(appmw.Authenticator(tokens), need(model.RightsTSD)).Post("/cz/scan", czH.Scan)
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
				r.Get("/barcodes", barcodeH.List)                  // все привязки ШК (кэш устройства, P2-02)
				r.Get("/barcodes/{code}", barcodeH.GetByCode)      // товар по ШК или 404
				r.Get("/goods/{id}/barcodes", barcodeH.ListByGood) // все ШК товара (P-FS-12)
				// Привязки меняет склад — любое право ТСД (ADHOC-49).
				r.With(need(model.RightsTSD)).Post("/barcodes", barcodeH.Bind)                              // привязать ШК к товару
				r.With(need(model.RightsTSD)).Delete("/barcodes/{code}", barcodeH.Unbind)                   // отвязать ошибочный ШК (P-FS-12)
				r.With(need(model.RightsTSD)).Get("/barcodes/{code}/cz-stock", barcodeH.CZStock)            // марки ЧЗ ШК на складе (ADHOC-53)
				r.With(need(model.RightTSDStockRegrade)).Post("/barcodes/{code}/regrade", barcodeH.Regrade) // перепривязка с пересортом (ADHOC-53)
				r.With(need(model.RightsTSD)).Post("/goods/{id}/barcode", barcodeH.GenerateInternal)        // внутренний EAN-13 товару без ШК (P4-07)
			})
		}

		// Батч операций из офлайн-очереди устройства (P2-05) — сотруднику: очередь копится
		// на ТСД кладовщика. Дедуп по operation_id: повтор не применяет эффект второй раз.
		if svc.Operations != nil {
			opsH := NewOperationsHandler(svc.Operations)
			r.Group(func(r chi.Router) {
				r.Use(appmw.Authenticator(tokens))
				r.Use(need(model.RightsTSD))
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
				r.Use(need(model.RightTSDReceipt, model.RightTSDStockEntry))
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
				r.Use(need(model.RightTSDPutaway, model.RightTSDStocktakeCount, model.RightTSDStocktakeManage,
					model.RightTSDPickingReturn))
				r.Get("/tasks", taskH.Current)               // текущие: пул и свои взятые
				r.Get("/tasks/completed", taskH.Completed)   // лента «Завершённые»
				r.Get("/tasks/executors", taskH.Executors)   // варианты фильтра по исполнителю
				r.Get("/tasks/{id}", taskH.Get)              // карточка с заходами
				r.Post("/tasks/{id}/take", taskH.Take)       // взять в работу
				r.Post("/tasks/{id}/release", taskH.Release) // отказаться
			})
		}

		// Пересчёт (P10-03). Ячейки, взятие и начало подсчёта — сотруднику на ТСД, только со
		// связью: кто держит ячейку и что в ней ожидалось, знает сервер. Факт ячейки — операция
		// очереди stocktake_cell_submit, работает без связи. Заводит и закрывает пересчёт старший
		// смены — «Пересчёты: заводить и закрывать» в портале или на ТСД (ADHOC-50). Ход читает и портал.
		if svc.Stocktake != nil {
			stH := NewStocktakeHandler(svc.Stocktake)
			r.Group(func(r chi.Router) {
				r.Use(appmw.Authenticator(tokens))
				r.Get("/stocktakes/{id}", stH.Get)         // ход выполнения
				r.Get("/stocktakes/{id}/cells", stH.Cells) // свободные и свои ячейки
				// Идёт ли подсчёт (ADHOC-48) — спрашивают все потоки движения на ТСД.
				r.With(need(model.RightsTSD)).Get("/cells/{id}/stocktake-count", stH.CellCounting)
			})
			r.Group(func(r chi.Router) {
				r.Use(appmw.Authenticator(tokens))
				r.Use(need(model.RightTSDStocktakeCount))
				r.Get("/stocktake-cells/{id}", stH.Cell)             // своя ячейка с позициями
				r.Post("/stocktake-cells/{id}/take", stH.Take)       // взять ячейку
				r.Post("/stocktake-cells/{id}/release", stH.Release) // отказаться
				r.Post("/stocktake-cells/{id}/start", stH.Start)     // скан ячейки: снимок
			})
			r.Group(func(r chi.Router) {
				r.Use(appmw.Authenticator(tokens))
				r.With(need(model.RightStocktakeView, model.RightStocktakeManage)).
					Get("/stocktakes", stH.List) // список для портала (P10-05)
				r.With(need(model.RightStocktakeView, model.RightStocktakeManage)).
					Get("/stocktakes/{id}/lines", stH.Lines) // ожидалось и посчитано (окно «Ход»)
				// Заводит и закрывает старший смены — из портала или с ТСД.
				r.With(need(model.RightStocktakeManage, model.RightTSDStocktakeManage)).
					Post("/stocktakes", stH.Create) // завести по области
				r.With(need(model.RightStocktakeManage, model.RightTSDStocktakeManage)).
					Post("/stocktakes/{id}/close", stH.Close) // закрыть, досрочно — с force
			})
		}

		// История перемещений (ADHOC-28) — сотруднику: лента «Завершённые» в разделе
		// «Перемещение», перемещения всего склада. Только онлайн, только чтение: проводит
		// перемещение операция очереди movement_submit.
		if svc.MovementHistory != nil {
			mhH := NewMovementHistoryHandler(svc.MovementHistory)
			r.Group(func(r chi.Router) {
				r.Use(appmw.Authenticator(tokens))
				r.Use(need(model.RightTSDMovement))
				r.Get("/movements", mhH.List)                // лента, свежие сверху
				r.Get("/movements/executors", mhH.Executors) // варианты фильтра по исполнителю
				r.Get("/movements/{id}", mhH.Get)            // запись со строками
			})
		}

		// Внутренние склады (P6-07-1, ADHOC-29). Читает сотрудник: ТСД выбирает, каким складом
		// пометить короб или товар, и подписывает помеченное. Ведёт справочник право «склады» из
		// портала: завести, переименовать, скрыть, удалить без остатка и истории.
		if svc.InternalWarehouse != nil {
			iwH := NewInternalWarehouseHandler(svc.InternalWarehouse)
			r.Group(func(r chi.Router) {
				r.Use(appmw.Authenticator(tokens))
				r.Get("/internal-warehouses", iwH.List) // все, и скрытые; по умолчанию первым
			})
			r.Group(func(r chi.Router) {
				r.Use(appmw.Authenticator(tokens))
				r.Use(need(model.RightSettingsWarehouses))
				r.Post("/internal-warehouses", iwH.Create)
				r.Patch("/internal-warehouses/{id}", iwH.Update)
				r.Delete("/internal-warehouses/{id}", iwH.Delete)
			})
		}

		// Причины проблем и варианты решения (ADHOC-55). Читает сотрудник: ТСД выбирает причину при
		// пометке и подписывает ею проблемы. Ведёт справочник право «причины проблем» из портала;
		// удаления нет — только «неактивен».
		if svc.ProblemReason != nil {
			prH := NewProblemReasonHandler(svc.ProblemReason)
			r.Group(func(r chi.Router) {
				r.Use(appmw.Authenticator(tokens))
				r.Get("/problem-reasons", prH.List) // причины и варианты, и неактивные
			})
			r.Group(func(r chi.Router) {
				r.Use(appmw.Authenticator(tokens))
				r.Use(need(model.RightSettingsProblemReasons))
				r.Post("/problem-reasons", prH.CreateReason)
				r.Patch("/problem-reasons/{code}", prH.UpdateReason)
				r.Post("/problem-resolutions", prH.CreateResolution)
				r.Patch("/problem-resolutions/{id}", prH.UpdateResolution)
			})
		}

		// «Проблемы склада» (P6-07-3) — офис из портала: рабочий список и решение по проблеме
		// («Провести»: списать по документу 1С, разместить, вернуть поставщику). Право «проблемы
		// склада»: решение меняет остаток.
		if svc.Problem != nil {
			prH := NewProblemHandler(svc.Problem)
			// Склад видит проблемы на ТСД — сотруднику, только чтение: открытые на вкладке
			// «Текущие» (ADHOC-35) и ленту решённых офисом (ADHOC-34). Решение — только офису.
			r.With(appmw.Authenticator(tokens), need(model.RightTSDProblemsView, model.RightTSDProblemsMark)).Get("/problems/current", prH.Current)
			r.With(appmw.Authenticator(tokens), need(model.RightTSDProblemsView, model.RightTSDProblemsMark)).Get("/problems/resolved", prH.Resolved)
			r.Group(func(r chi.Router) {
				r.Use(appmw.Authenticator(tokens))
				r.With(need(model.RightProblemsView, model.RightProblemsResolve)).
					Get("/problems", prH.List) // открытые сверху
				r.With(need(model.RightProblemsResolve)).
					Post("/problems/{id}/resolve", prH.Resolve) // «Провести» решение
			})
		}

		// «Сборка-отгрузка» (P8-02) — загрузка «Реестра» 1С из портала: предпросмотр ничего не
		// пишет, загрузка — после подтверждения оператора. Оба шага — право «загружать реестр».
		if svc.Picking != nil {
			pkH := NewPickingHandler(svc.Picking)
			r.Group(func(r chi.Router) {
				r.Use(appmw.Authenticator(tokens))
				r.Use(need(model.RightPickingLoad))
				r.Post("/picking/registry/preview", pkH.PreviewRegistry)
				r.Post("/picking/registry/load", pkH.LoadRegistry)
			})
		}

		// «Сборка-отгрузка» (P8-03) — заказы на дату накладной и окно деталей: право «смотреть»
		// или «снимать с исполнителя» (снять, не видя заказа, нельзя). Выгрузка Excel и снятие —
		// свои права.
		if svc.PickingPortal != nil {
			ppH := NewPickingPortalHandler(svc.PickingPortal)
			r.Group(func(r chi.Router) {
				r.Use(appmw.Authenticator(tokens))
				r.With(need(model.RightPickingView, model.RightPickingRelease)).Get("/picking/portal/orders", ppH.Orders)
				r.With(need(model.RightPickingView, model.RightPickingRelease)).Get("/picking/portal/orders/{id}", ppH.Order)
				r.With(need(model.RightPickingRelease)).Post("/picking/portal/orders/{id}/release", ppH.Release)
				r.With(need(model.RightPickingDownload)).Get("/picking/portal/export.xlsx", ppH.ExportXLSX)
			})
			// Карточка заказа на ТСД (ADHOC-62) — те же данные, что окно деталей портала, только
			// чтение: «Завершённые» в «СБОРКЕ» показывают план/факт, короба и журнал. Право
			// кладовщика сборки, а не портала.
			r.Group(func(r chi.Router) {
				r.Use(appmw.Authenticator(tokens))
				r.Use(need(model.RightTSDPicking))
				r.Get("/picking/orders/{id}/card", ppH.Order)
			})
		}

		// Сборка на ТСД (P9-04) — право «собирать и отгружать». Онлайн: заказ закрепляется за
		// одним кладовщиком на сервере.
		if svc.PickingTask != nil {
			ptH := NewPickingTSDHandler(svc.PickingTask)
			r.Group(func(r chi.Router) {
				r.Use(appmw.Authenticator(tokens))
				r.Use(need(model.RightTSDPicking))
				r.Get("/picking/orders", ptH.Orders)                                 // список «СБОРКА»
				r.Get("/picking/orders/shipped", ptH.ShippedOrders)                  // «Завершённые» за дату
				r.Get("/picking/orders/{id}", ptH.Order)                             // заказ с подбором
				r.Post("/picking/orders/{id}/take", ptH.Take)                        // взять в работу
				r.Post("/picking/orders/{id}/release", ptH.Release)                  // отказаться
				r.Post("/picking/orders/{id}/boxes", ptH.AddBox)                     // короб отгрузки
				r.Delete("/picking/orders/{id}/boxes/{boxId}", ptH.DropBox)          // убрать пустой короб
				r.Post("/picking/orders/{id}/lines/{lineId}/shortage", ptH.Shortage) // «не хватает»
				r.Post("/picking/orders/{id}/complete", ptH.Complete)                // «Завершить сборку» (P9-07)
				r.Get("/picking/orders/{id}/shipment", ptH.Shipment)                 // короба «N из M»
				r.Post("/picking/orders/{id}/labels", ptH.Labels)                    // печать ярлыков
				r.Post("/picking/orders/{id}/ship", ptH.Ship)                        // «Отгрузить»
			})
			// Возврат на места (P9-07-1) — задание из «ЗАДАНИЙ», своё право.
			r.Group(func(r chi.Router) {
				r.Use(appmw.Authenticator(tokens))
				r.Use(need(model.RightTSDPickingReturn))
				r.Get("/picking/orders/{id}/return", ptH.Return) // что вернуть на места
			})
		}

		// Фото к проблемам склада (ADHOC-45) — сотруднику: снимает кладовщик на ТСД, смотрят и
		// склад, и офис. Добавить фото можно только к открытой проблеме — это решает сервис.
		if svc.ProblemPhoto != nil {
			phH := NewProblemPhotoHandler(svc.ProblemPhoto)
			r.Group(func(r chi.Router) {
				r.Use(appmw.Authenticator(tokens))
				r.Get("/problems/{id}/photos/{photoId}", phH.Get)
				r.With(need(model.RightTSDProblemsMark)).Put("/problems/{id}/photos/{photoId}", phH.Put)
			})
		}

		// Просмотр содержимого ячеек и коробов (P5-05) — сотруднику: кладовщик сканирует ячейку
		// или короб на ТСД. Только чтение. Снимок для кэша терминала сжимается: это весь склад
		// одним ответом, а повторяющиеся идентификаторы жмутся в разы.
		if svc.Contents != nil {
			contentsH := NewContentsHandler(svc.Contents)
			r.Group(func(r chi.Router) {
				r.Use(appmw.Authenticator(tokens))
				// Снимок — ещё и странице портала «Остатки склада» (ADHOC-56).
				r.With(need(model.RightsTSD, model.RightStockView), chimw.Compress(5, "application/json")).
					Get("/contents/snapshot", contentsH.Snapshot) // кэш ТСД: короба и россыпь
				r.Group(func(r chi.Router) {
					r.Use(need(model.RightsTSD))
					r.Get("/cells/{id}/contents", contentsH.CellContents)  // что лежит в ячейке
					r.Get("/load-units/{id}/card", contentsH.LoadUnitCard) // что за короб и где
					// P5-05-1: поиск по короткому коду с ярлыка и история — для перепечатки ярлыка.
					r.Get("/load-units", contentsH.SearchLoadUnits)              // ?code=… — все короба
					r.Get("/load-units/{id}/history", contentsH.LoadUnitHistory) // приёмка и переносы
					r.Get("/load-units/cz/{code}", contentsH.LoadUnitByCZCode)   // короб ЧЗ по SSCC
				})
			})
		}

		// Сессия ввода остатков (P-FastStart) — тоже сотруднику: кладовщик проходит склад.
		if svc.StockEntry != nil {
			seH := NewStockEntryHandler(svc.StockEntry)
			r.Group(func(r chi.Router) {
				r.Use(appmw.Authenticator(tokens))
				r.Use(need(model.RightTSDStockEntry))
				r.Post("/stock-entry/sessions", seH.Start)                  // открыть сессию
				r.Post("/stock-entry/sessions/{id}/cells", seH.Checkpoint)  // checkpoint ячейки
				r.Post("/stock-entry/sessions/{id}/finalize", seH.Finalize) // финал → запись в stock
			})
		}

		// Должности и пользователи (ADHOC-49) — «Настройки: должности и пользователи».
		if svc.Users != nil {
			uH := NewUserAdminHandler(svc.Users)
			r.Group(func(r chi.Router) {
				r.Use(appmw.Authenticator(tokens))
				r.Use(need(model.RightSettingsUsers))
				r.Get("/rights", uH.Rights)                    // все права, в порядке показа
				r.Get("/positions", uH.Positions)              // должности с правами и числом людей
				r.Post("/positions", uH.CreatePosition)        // завести
				r.Patch("/positions/{id}", uH.UpdatePosition)  // название и права
				r.Delete("/positions/{id}", uH.DeletePosition) // удалить пустую
				r.Get("/users", uH.Users)                      // все, и заблокированные
				r.Post("/users", uH.CreateUser)                // завести: бейдж или логин с паролем
				r.Patch("/users/{id}", uH.UpdateUser)          // ФИО, должность, блокировка, новый вход
			})
		}

		// «Бейджи» на ТСД (ADHOC-65) — любое из трёх прав; чей бейдж можно печатать, решает
		// сервис по самому широкому из них.
		if svc.Badge != nil {
			bH := NewBadgeHandler(svc.Badge)
			r.Group(func(r chi.Router) {
				r.Use(appmw.Authenticator(tokens))
				r.Use(need(model.RightTSDBadgesOwn, model.RightTSDBadgesStaff, model.RightTSDBadgesAll))
				r.Get("/badges", bH.Holders)    // кого можно печатать
				r.Get("/badges/{id}", bH.Badge) // номер к печати
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

// noRights — источник прав, когда его не подключили (урезанная сборка в тесте): у
// пользователя нет ни одного права, ручки с правом отвечают 403.
type noRights struct{}

func (noRights) UserAccess(context.Context, string) (model.Access, error) {
	return model.Access{Active: true}, nil
}
