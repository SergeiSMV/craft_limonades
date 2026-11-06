package handler

import (
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"strings"

	"github.com/go-chi/chi/v5"

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
// отсутствующее поле не меняется; side_card=true ячейке без стеллажа не ставится (карточки у неё
// нет). 200 {cells_updated} / 400 / 404 / 409.
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

// floorCellMaxBody — потолок тела добавления и переименования напольной ячейки: один адрес.
const floorCellMaxBody = 4 << 10

// decodeFloorCell — тело {"address": "D-Н-П"}; ошибка разбора — 400 уже отправлен.
func decodeFloorCell(w http.ResponseWriter, r *http.Request) (model.FloorCellInput, bool) {
	var in model.FloorCellInput
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, floorCellMaxBody)).Decode(&in); err != nil {
		writeError(w, http.StatusBadRequest, "ожидается {\"address\": \"D-Н-П\"}")
		return in, false
	}
	return in, true
}

// CreateFloorCell: POST /api/v1/cells/floor?warehouse=SHB — завести напольную ячейку (ADHOC-61).
// Тело {"address": "D-Н-П"}. 201 {id, address} / 400 (адрес) / 404 (склад) / 409 (адрес занят).
func (h *CellSetupHandler) CreateFloorCell(w http.ResponseWriter, r *http.Request) {
	in, ok := decodeFloorCell(w, r)
	if !ok {
		return
	}
	cell, err := h.svc.CreateFloorCell(r.Context(), cellsWarehouse(r), in)
	if err != nil {
		cellSetupError(w, r, err)
		return
	}
	writeJSON(w, http.StatusCreated, cell)
}

// RenameFloorCell: PATCH /api/v1/cells/floor/{id}?warehouse=SHB — новый адрес напольной ячейки.
// 200 {id, address} / 400 / 404 (нет такой напольной ячейки) / 409 (адрес занят).
func (h *CellSetupHandler) RenameFloorCell(w http.ResponseWriter, r *http.Request) {
	in, ok := decodeFloorCell(w, r)
	if !ok {
		return
	}
	cell, err := h.svc.RenameFloorCell(r.Context(), cellsWarehouse(r), chi.URLParam(r, "id"), in)
	if err != nil {
		cellSetupError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, cell)
}

// DeleteFloorCell: DELETE /api/v1/cells/floor/{id}?warehouse=SHB — убрать пустую напольную
// ячейку. 204 / 400 / 404 / 409 (в ячейке товар или короба).
func (h *CellSetupHandler) DeleteFloorCell(w http.ResponseWriter, r *http.Request) {
	if err := h.svc.DeleteFloorCell(r.Context(), cellsWarehouse(r), chi.URLParam(r, "id")); err != nil {
		cellSetupError(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// cellSetupError — ответ на ошибку страницы «Ячейки»; текст — для экрана портала.
func cellSetupError(w http.ResponseWriter, r *http.Request, err error) {
	switch {
	case errors.Is(err, repository.ErrNotFound):
		if chi.URLParam(r, "id") != "" {
			writeError(w, http.StatusNotFound, "напольная ячейка не найдена - обновите страницу")
			return
		}
		writeError(w, http.StatusNotFound, "склад не найден")
	case errors.Is(err, service.ErrNoCellsSelected), errors.Is(err, service.ErrEmptyCellsPatch),
		errors.Is(err, service.ErrTooManyCells), errors.Is(err, service.ErrInvalidCellIDs),
		errors.Is(err, service.ErrInvalidFloorAddress):
		writeError(w, http.StatusBadRequest, err.Error())
	case errors.Is(err, repository.ErrForeignCells):
		writeError(w, http.StatusConflict, "часть ячеек не найдена на складе — обновите страницу")
	case errors.Is(err, repository.ErrCellExists), errors.Is(err, repository.ErrCellNotEmpty):
		writeError(w, http.StatusConflict, err.Error())
	default:
		slog.ErrorContext(r.Context(), "cell setup failed", "error", err)
		writeError(w, http.StatusInternalServerError, "внутренняя ошибка")
	}
}
