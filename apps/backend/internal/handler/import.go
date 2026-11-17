package handler

import (
	"context"
	"io"
	"log/slog"
	"net/http"
	"strings"

	"craftwms/internal/service"
)

// maxImportUpload - потолок размера загружаемого файла (выгрузки крошечные; лимит от злоупотреблений).
const maxImportUpload = 32 << 20 // 32 MiB

// Дефолты физического склада для импорта ячеек: на пилоте склад один - «Шабулина».
// Переопределяются полями формы warehouse_code/warehouse_name (задел под несколько складов).
// ⚠ Код склада - согласовать с заказчиком (короткий идентификатор для отчётов/адресации).
const (
	defaultWarehouseCode = "SHB"
	defaultWarehouseName = "Шабулина"
)

// directoryImporter - то, что обработчику импорта нужно от сервиса импорта справочников.
type directoryImporter interface {
	ImportGoods(ctx context.Context, r io.ReadSeeker) (*service.ImportReport, error)
	ImportCells(ctx context.Context, r io.Reader, warehouseCode, warehouseName string) (*service.CellsImportReport, error)
}

// ImportHandler - HTTP-обработчики импорта справочников из файлов.
type ImportHandler struct {
	svc directoryImporter
}

// NewImportHandler создаёт обработчик импорта.
func NewImportHandler(svc directoryImporter) *ImportHandler {
	return &ImportHandler{svc: svc}
}

// ImportGoods: POST /api/v1/import/goods - multipart-форма с .xls-выгрузкой номенклатуры в поле "file".
// Только для admin. Возвращает отчёт (создано/обновлено/пропущено).
func (h *ImportHandler) ImportGoods(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, maxImportUpload)

	file, _, err := r.FormFile("file")
	if err != nil {
		writeError(w, http.StatusBadRequest, "ожидается multipart-форма с файлом в поле 'file'")
		return
	}
	defer func() { _ = file.Close() }()

	report, err := h.svc.ImportGoods(r.Context(), file)
	if err != nil {
		// Не смогли прочитать файл / нет обязательной колонки - это про ввод → 422.
		slog.Warn("import goods failed", "error", err)
		writeError(w, http.StatusUnprocessableEntity, "не удалось импортировать: "+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, report)
}

// ImportCells: POST /api/v1/import/cells - multipart-форма с .xlsx-файлом ячеек в поле "file".
// Необязательные поля формы warehouse_code/warehouse_name задают физический склад (дефолт - «Шабулина»).
// Только для admin. Возвращает отчёт (создано/обновлено/пропущено).
func (h *ImportHandler) ImportCells(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, maxImportUpload)

	file, _, err := r.FormFile("file")
	if err != nil {
		writeError(w, http.StatusBadRequest, "ожидается multipart-форма с файлом в поле 'file'")
		return
	}
	defer func() { _ = file.Close() }()

	// Склад в файле не задан - берём из формы, иначе пилотные дефолты.
	code := strings.TrimSpace(r.FormValue("warehouse_code"))
	if code == "" {
		code = defaultWarehouseCode
	}
	name := strings.TrimSpace(r.FormValue("warehouse_name"))
	if name == "" {
		name = defaultWarehouseName
	}

	report, err := h.svc.ImportCells(r.Context(), file, code, name)
	if err != nil {
		slog.Warn("import cells failed", "error", err)
		writeError(w, http.StatusUnprocessableEntity, "не удалось импортировать: "+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, report)
}
