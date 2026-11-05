package handler

import (
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"strings"

	"craftwms/internal/model"
	"craftwms/internal/repository"
	"craftwms/internal/service"
)

// cellSetupMaxBody — потолок тела правки галочек: 5000 UUID в JSON — около 200 КБ.
const cellSetupMaxBody = 512 << 10

// CellSetupHandler — страница «Ячейки» портала (ADHOC-57): список ячеек со стеллажами и
// настройками этикеток, правка галочек, выгрузка в .xlsx формата rack_labels.
type CellSetupHandler struct {
	svc *service.CellSetupService
}

// NewCellSetupHandler создаёт обработчик страницы «Ячейки».
func NewCellSetupHandler(svc *service.CellSetupService) *CellSetupHandler {
	return &CellSetupHandler{svc: svc}
}

// cellsWarehouse — код склада из ?warehouse=, пусто — склад пилота (как у этикеток).
func cellsWarehouse(r *http.Request) string {
	if code := strings.TrimSpace(r.URL.Query().Get("warehouse")); code != "" {
		return code
	}
	return defaultLabelsWarehouse
}

// Setup: GET /api/v1/cells/setup?warehouse=SHB — все ячейки склада (без ячейки приёмки) и его
// стеллажи. 200 / 404 (склад не найден).
func (h *CellSetupHandler) Setup(w http.ResponseWriter, r *http.Request) {
	setup, err := h.svc.Setup(r.Context(), cellsWarehouse(r))
	if err != nil {
		cellSetupError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, setup)
}

// UpdateSettings: PATCH /api/v1/cells/setup?warehouse=SHB — галочки у выбранных ячеек.
// Тело: {"cell_ids": [...], "label_small"?, "is_floor"?, "label_barcode"?, "side_card"?};
// отсутствующее поле не меняется. 200 {cells_updated, racks_updated} / 400 / 404 / 409.
func (h *CellSetupHandler) UpdateSettings(w http.ResponseWriter, r *http.Request) {
	var req model.CellSettingsPatch
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, cellSetupMaxBody)).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "ожидается {\"cell_ids\": [...], \"label_small\"|\"is_floor\"|\"label_barcode\"|\"side_card\": true|false}")
		return
	}
	res, err := h.svc.UpdateSettings(r.Context(), cellsWarehouse(r), req)
	if err != nil {
		cellSetupError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, res)
}

// ExportXLSX: GET /api/v1/cells/export.xlsx?warehouse=SHB — ячейки и стеллажи склада файлом
// формата rack_labels (листы cells и racks). 200 (attachment) / 404.
func (h *CellSetupHandler) ExportXLSX(w http.ResponseWriter, r *http.Request) {
	data, name, err := h.svc.ExportXLSX(r.Context(), cellsWarehouse(r))
	if err != nil {
		cellSetupError(w, r, err)
		return
	}
	w.Header().Set("Content-Type", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
	w.Header().Set("Content-Disposition", fmt.Sprintf(`attachment; filename="%s"`, name))
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(data)
}

// cellSetupError — ответ на ошибку страницы «Ячейки»; текст — для экрана портала.
func cellSetupError(w http.ResponseWriter, r *http.Request, err error) {
	switch {
	case errors.Is(err, repository.ErrNotFound):
		writeError(w, http.StatusNotFound, "склад не найден")
	case errors.Is(err, service.ErrNoCellsSelected), errors.Is(err, service.ErrEmptyCellsPatch),
		errors.Is(err, service.ErrTooManyCells), errors.Is(err, service.ErrInvalidCellIDs):
		writeError(w, http.StatusBadRequest, err.Error())
	case errors.Is(err, repository.ErrForeignCells):
		writeError(w, http.StatusConflict, "часть ячеек не найдена на складе — обновите страницу")
	default:
		slog.ErrorContext(r.Context(), "cell setup failed", "error", err)
		writeError(w, http.StatusInternalServerError, "внутренняя ошибка")
	}
}
