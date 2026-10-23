package handler

import (
	"encoding/json"
	"log/slog"
	"net/http"

	"github.com/go-chi/chi/v5"
)

// SetGoodCZMarked: PATCH /api/v1/goods/{id}/cz-marked {cz_marked} — правка признака
// «маркируемый» у товара (CZ-05), только admin.
//
// Признак обычно ставится сам — привязкой ШК из марки и принятой маркой (долг 16); ручка
// исправляет ошибку. Ответ — новое значение: карточка товара на ТСД показывает его сразу.
func (h *CZHandler) SetGoodCZMarked(w http.ResponseWriter, r *http.Request) {
	var req struct {
		CZMarked *bool `json:"cz_marked"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, czMaxBody)).Decode(&req); err != nil || req.CZMarked == nil {
		writeError(w, http.StatusBadRequest, "ожидается {\"cz_marked\": true|false}")
		return
	}
	id := chi.URLParam(r, "id")
	if err := h.svc.SetGoodCZMarked(r.Context(), id, *req.CZMarked); err != nil {
		code, msg := czErrorResponse(err)
		if code >= http.StatusInternalServerError {
			slog.ErrorContext(r.Context(), "set good cz_marked failed", "error", err)
		}
		writeError(w, code, msg)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"id": id, "cz_marked": *req.CZMarked})
}
