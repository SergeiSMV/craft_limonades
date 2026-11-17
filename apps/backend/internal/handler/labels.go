package handler

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"strings"

	"craftwms/internal/labels"
	"craftwms/internal/model"
)

// defaultLabelsWarehouse - склад по умолчанию для этикеток (на пилоте один - «Шабулина»).
const defaultLabelsWarehouse = "SHB"

// cellLabels - то, что обработчику этикеток нужно от сервиса.
type cellLabels interface {
	CellLabelsPDF(ctx context.Context, warehouseCode, kind string, cellIDs []string) ([]byte, string, error)
}

// LabelHandler - PDF этикеток ячеек и карточек на стойку (ADHOC-57, геометрия rack_labels).
type LabelHandler struct {
	svc cellLabels
}

// NewLabelHandler создаёт обработчик этикеток.
func NewLabelHandler(svc cellLabels) *LabelHandler {
	return &LabelHandler{svc: svc}
}

// labelsRequest - что печатать: вид PDF и выбранные ячейки (пусто - весь склад).
type labelsRequest struct {
	Kind    string   `json:"kind"`
	CellIDs []string `json:"cell_ids"`
}

// CellLabelsPDF: POST /api/v1/cells/labels.pdf?warehouse=SHB - тело {"kind": "large"|"small"|"cards",
// "cell_ids": [...]}. POST, а не GET: выборка из тысяч id в адрес не влезает.
// 200 application/pdf (labels_large.pdf, labels_small.pdf, side_cards.pdf) / 400 / 404 /
// 409 (чужие ячейки) / 422 (печатать нечего или не влезает - причины в тексте ошибки).
func (h *LabelHandler) CellLabelsPDF(w http.ResponseWriter, r *http.Request) {
	var req labelsRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, cellSetupMaxBody)).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "ожидается {\"kind\": \"large\"|\"small\"|\"cards\", \"cell_ids\": [...]}")
		return
	}
	code := strings.TrimSpace(r.URL.Query().Get("warehouse"))
	if code == "" {
		code = defaultLabelsWarehouse
	}

	pdf, name, err := h.svc.CellLabelsPDF(r.Context(), code, req.Kind, req.CellIDs)
	var fit *labels.FitError
	switch {
	case err == nil:
	case errors.Is(err, model.ErrNotFound):
		writeError(w, http.StatusNotFound, "склад не найден")
		return
	case errors.Is(err, model.ErrUnknownLabelKind), errors.Is(err, model.ErrInvalidCellIDs):
		writeError(w, http.StatusBadRequest, err.Error())
		return
	case errors.Is(err, model.ErrForeignCells):
		writeError(w, http.StatusConflict, "часть ячеек не найдена на складе - обновите страницу")
		return
	case errors.Is(err, labels.ErrNothingToPrint):
		writeError(w, http.StatusUnprocessableEntity, "в выбранных ячейках нет этикеток этого вида")
		return
	case errors.As(err, &fit):
		writeError(w, http.StatusUnprocessableEntity, fit.Error())
		return
	default:
		slog.ErrorContext(r.Context(), "cell labels pdf failed", "warehouse", code, "kind", req.Kind, "error", err)
		writeError(w, http.StatusInternalServerError, "внутренняя ошибка")
		return
	}

	w.Header().Set("Content-Type", "application/pdf")
	w.Header().Set("Content-Disposition", fmt.Sprintf(`attachment; filename="%s"`, name))
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(pdf)
}
