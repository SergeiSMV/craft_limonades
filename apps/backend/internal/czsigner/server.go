package czsigner

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
)

// maxDataSize - предел тела /sign. Строка auth/key - десятки байт; предел защищает
// подписант от случайной отправки чего-то большого.
const maxDataSize = 64 << 10

// healthData - что подписывает пробная подпись /health. Смысла не несёт, проверяет цепочку
// «сертификат найден → ключ открылся → подпись вышла».
var healthData = []byte("cz-signer health")

// Signer - то, что умеет подписывать; в службе - Cryptcp, в тестах - подстановка.
type Signer interface {
	Sign(ctx context.Context, data []byte) ([]byte, error)
}

// NewHandler - HTTP-обработчик подписанта. Слушает unix-сокет, поэтому авторизации нет:
// доступ к сокету даёт группа файла (см. cmd/cz-signer).
//
//	POST /sign   - тело: байты для подписи; ответ: подпись DER (application/octet-stream).
//	GET  /health - пробная подпись; 200 - подписант готов подписывать.
//
// Ошибки - JSON {"error": "..."}: 400 - пустое или слишком большое тело, 503 - подписать
// не удалось. Подробность (вывод cryptcp) уходит только в журнал службы.
func NewHandler(log *slog.Logger, s Signer) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /sign", func(w http.ResponseWriter, r *http.Request) {
		data, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxDataSize))
		if err != nil {
			writeError(w, http.StatusBadRequest, "body too large")
			return
		}
		if len(data) == 0 {
			writeError(w, http.StatusBadRequest, "empty body")
			return
		}
		sig, err := s.Sign(r.Context(), data)
		if err != nil {
			log.Error("sign failed", "error", err)
			writeError(w, http.StatusServiceUnavailable, "signing failed")
			return
		}
		w.Header().Set("Content-Type", "application/octet-stream")
		_, _ = w.Write(sig)
	})
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, r *http.Request) {
		if _, err := s.Sign(r.Context(), healthData); err != nil {
			log.Error("health sign failed", "error", err)
			writeError(w, http.StatusServiceUnavailable, "signing failed")
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"status":"ok"}`))
	})
	return mux
}

// writeError - ответ-ошибка в JSON.
func writeError(w http.ResponseWriter, code int, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(map[string]string{"error": msg})
}
