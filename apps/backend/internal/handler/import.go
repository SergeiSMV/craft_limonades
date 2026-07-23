package handler

import (
	"log/slog"
	"net/http"

	"craftwms/internal/service"
)

// maxImportUpload — потолок размера загружаемого файла (выгрузки крошечные; лимит от злоупотреблений).
const maxImportUpload = 32 << 20 // 32 MiB

// ImportHandler — HTTP-обработчики импорта справочников из файлов.
type ImportHandler struct {
	svc *service.ImportService
}

// NewImportHandler создаёт обработчик импорта.
func NewImportHandler(svc *service.ImportService) *ImportHandler {
	return &ImportHandler{svc: svc}
}

// ImportGoods: POST /import/goods — multipart-форма с .xls-выгрузкой номенклатуры в поле "file".
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
		// Не смогли прочитать файл / нет обязательной колонки — это про ввод → 422.
		slog.Warn("import goods failed", "error", err)
		writeError(w, http.StatusUnprocessableEntity, "не удалось импортировать: "+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, report)
}
