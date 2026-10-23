package handler

import (
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"strings"

	"craftwms/internal/repository"
	"craftwms/internal/service"
)

// defaultLabelsWarehouse — склад по умолчанию для этикеток (на пилоте один — «Шабулина»).
const defaultLabelsWarehouse = "SHB"

// LabelHandler — выдача PDF-этикеток ячеек (P-FS-05). Только admin (печать этикеток — из портала).
type LabelHandler struct {
	svc *service.LabelService
}

// NewLabelHandler создаёт обработчик этикеток.
func NewLabelHandler(svc *service.LabelService) *LabelHandler {
	return &LabelHandler{svc: svc}
}

// CellLabelsPDF: GET /api/v1/cells/labels.pdf?warehouse=SHB — PDF-этикеток ячеек склада.
// 200 application/pdf (attachment) / 404 (склад не найден). Пустой параметр → дефолтный склад.
func (h *LabelHandler) CellLabelsPDF(w http.ResponseWriter, r *http.Request) {
	code := strings.TrimSpace(r.URL.Query().Get("warehouse"))
	if code == "" {
		code = defaultLabelsWarehouse
	}

	pdf, err := h.svc.CellLabelsPDF(r.Context(), code)
	if errors.Is(err, repository.ErrNotFound) {
		writeError(w, http.StatusNotFound, "склад не найден")
		return
	}
	if err != nil {
		slog.ErrorContext(r.Context(), "cell labels pdf failed", "warehouse", code, "error", err)
		writeError(w, http.StatusInternalServerError, "внутренняя ошибка")
		return
	}

	w.Header().Set("Content-Type", "application/pdf")
	w.Header().Set("Content-Disposition", fmt.Sprintf(`attachment; filename="cell-labels-%s.pdf"`, code))
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(pdf)
}
