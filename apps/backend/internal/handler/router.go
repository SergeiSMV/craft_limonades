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
// Как: chi-роутер с цепочкой middleware и регистрацией обработчиков.
// db (Pinger) может быть nil → /ready ответит 503. authSvc может быть nil (нет БД) →
// auth-роуты не регистрируются.
func NewRouter(log *slog.Logger, db Pinger, authSvc *service.AuthService, tokens *auth.TokenManager, importSvc *service.ImportService) http.Handler {
	r := chi.NewRouter()

	// Общие middleware для всех маршрутов:
	r.Use(chimw.RequestID)          // уникальный ID запроса — для трассировки в логах
	r.Use(chimw.Recoverer)          // перехват паник → 500 вместо падения процесса
	r.Use(appmw.RequestLogger(log)) // структурированное логирование каждого запроса

	// Пробы состояния.
	health := NewHealthHandler(db)
	r.Get("/health", health.Health) // liveness: процесс жив
	r.Get("/ready", health.Ready)   // readiness: БД доступна

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
		})
	}

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
