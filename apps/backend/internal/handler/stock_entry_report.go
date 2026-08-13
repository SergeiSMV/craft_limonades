package handler

import (
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"

	"craftwms/internal/repository"
	"craftwms/internal/service"
)

// xlsxContentType — MIME .xlsx (OOXML).
const xlsxContentType = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"

// StockEntryReportHandler — выдача Excel-отчёта «ввод остатков» (P-FS-08). Только admin (портал).
type StockEntryReportHandler struct {
	svc *service.StockEntryReportService
}

// NewStockEntryReportHandler создаёт обработчик отчёта.
func NewStockEntryReportHandler(svc *service.StockEntryReportService) *StockEntryReportHandler {
	return &StockEntryReportHandler{svc: svc}
}

// Report: GET /api/v1/stock-entry/sessions/{id}/report.xlsx — .xlsx «ввод остатков» по закрытой сессии.
// 200 .xlsx (attachment) / 404 (нет сессии) / 409 (сессия не завершена).
func (h *StockEntryReportHandler) Report(w http.ResponseWriter, r *http.Request) {
	sessionID := chi.URLParam(r, "id")
	data, filename, err := h.svc.Report(r.Context(), sessionID)
	switch {
	case errors.Is(err, repository.ErrSessionNotFound):
		writeError(w, http.StatusNotFound, "сессия не найдена")
		return
	case errors.Is(err, repository.ErrSessionNotClosed):
		writeError(w, http.StatusConflict, "сессия не завершена")
		return
	case err != nil:
		slog.Error("stock entry report failed", "session", sessionID, "error", err)
		writeError(w, http.StatusInternalServerError, "внутренняя ошибка")
		return
	}

	w.Header().Set("Content-Type", xlsxContentType)
	w.Header().Set("Content-Disposition", fmt.Sprintf(`attachment; filename="%s"`, filename))
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(data)
}

// documentResponse — элемент списка документов «ввод остатков» для портала.
type documentResponse struct {
	ID            string `json:"id"`
	WarehouseCode string `json:"warehouse_code"`
	WarehouseName string `json:"warehouse_name"`
	ClosedAt      string `json:"closed_at"` // RFC3339
	LinesCount    int    `json:"lines_count"`
}

// List: GET /api/v1/stock-entry/sessions — список документов «ввод остатков» (закрытые сессии).
func (h *StockEntryReportHandler) List(w http.ResponseWriter, r *http.Request) {
	docs, err := h.svc.ListDocuments(r.Context())
	if err != nil {
		slog.Error("stock entry documents list failed", "error", err)
		writeError(w, http.StatusInternalServerError, "внутренняя ошибка")
		return
	}
	out := make([]documentResponse, 0, len(docs))
	for _, d := range docs {
		out = append(out, documentResponse{
			ID:            d.ID,
			WarehouseCode: d.WarehouseCode,
			WarehouseName: d.WarehouseName,
			ClosedAt:      d.ClosedAt.Format(time.RFC3339),
			LinesCount:    d.LinesCount,
		})
	}
	writeJSON(w, http.StatusOK, out)
}
