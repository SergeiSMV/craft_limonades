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

// NewRouter собирает HTTP-роутер сервиса: общие middleware + маршруты.
//
// Что: единая точка сборки транспортного слоя.
// Зачем: сюда по мере роста подключаются все будущие ручки (справочники, операции).
// Как: chi-роутер с цепочкой middleware; прикладные ручки — под /api/v1, пробы — на корне.
// db (Pinger) может быть nil → /ready ответит 503. authSvc может быть nil (нет БД) →
// auth-роуты не регистрируются.
func NewRouter(log *slog.Logger, db Pinger, authSvc *service.AuthService, tokens *auth.TokenManager, importSvc *service.ImportService, catalogSvc *service.CatalogService, barcodeSvc *service.BarcodeService) http.Handler {
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
		if authSvc != nil {
			authH := NewAuthHandler(authSvc)

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
		if importSvc != nil {
			importH := NewImportHandler(importSvc)
			r.Group(func(r chi.Router) {
				r.Use(appmw.Authenticator(tokens))
				r.Use(appmw.RequireRole(model.RoleAdmin))
				r.Post("/import/goods", importH.ImportGoods) // .xls-выгрузка номенклатуры 1С
				r.Post("/import/cells", importH.ImportCells) // .xlsx-файл физических ячеек склада
			})
		}

		// Чтение справочников (товары/группы/поставщики/ячейки/остатки) — любому аутентифицированному
		// сотруднику (это кормит экраны ТСД, не только админку). Только GET, без изменений данных.
		if catalogSvc != nil {
			catalogH := NewCatalogHandler(catalogSvc)
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
		if barcodeSvc != nil {
			barcodeH := NewBarcodeHandler(barcodeSvc)
			r.Group(func(r chi.Router) {
				r.Use(appmw.Authenticator(tokens))
				r.Get("/barcodes/{code}", barcodeH.GetByCode) // товар по ШК или 404
				r.Post("/barcodes", barcodeH.Bind)            // привязать ШК к товару
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
