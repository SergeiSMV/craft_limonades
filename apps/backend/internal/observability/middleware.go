package observability

import (
	"net/http"

	"github.com/getsentry/sentry-go"
	chimw "github.com/go-chi/chi/v5/middleware"
)

// errAbortHandler — штатный обрыв ответа в net/http; такую панику не отправляем.
var errAbortHandler = http.ErrAbortHandler

// Middleware даёт запросу свой hub Bugsink и ловит паники (ADHOC-42).
//
// Что: у каждого запроса — копия hub с запросом (метод, путь, заголовки без секретов) и тегом
// `request_id`, тем же, что в журнале: событие и строку журнала можно сопоставить.
// Паника отправляется событием и пробрасывается дальше — ответ 500 и запись в журнал
// по-прежнему делает chi Recoverer, поэтому Middleware ставится ВНУТРИ него.
// Отправка выключена — запрос проходит без изменений.
func Middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !enabled() {
			next.ServeHTTP(w, r)
			return
		}
		hub := sentry.CurrentHub().Clone()
		hub.Scope().SetRequest(r)
		if id := chimw.GetReqID(r.Context()); id != "" {
			hub.Scope().SetTag("request_id", id)
		}
		ctx := sentry.SetHubOnContext(r.Context(), hub)
		defer func() {
			if v := recover(); v != nil {
				if !isAbort(v) {
					hub.RecoverWithContext(ctx, v)
				}
				panic(v)
			}
		}()
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}
