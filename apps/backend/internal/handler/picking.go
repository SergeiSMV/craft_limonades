package handler

import (
	"errors"
	"log/slog"
	"net/http"
	"strings"

	appmw "craftwms/internal/middleware"
	"craftwms/internal/service"
)

// PickingHandler — «Сборка-отгрузка» в портале (P8-02): загрузка «Реестра» 1С.
type PickingHandler struct {
	load *service.PickingLoadService
}

// NewPickingHandler создаёт обработчик сборки.
func NewPickingHandler(load *service.PickingLoadService) *PickingHandler {
	return &PickingHandler{load: load}
}

// PreviewRegistry: POST /api/v1/picking/registry/preview — multipart с .xlsx реестра в поле
// "file". Ничего не пишет: заказы файла против заказов той же даты, нераспознанные коды, ячейки
// вне WMS, нехватка остатка.
func (h *PickingHandler) PreviewRegistry(w http.ResponseWriter, r *http.Request) {
	h.registry(w, r, false)
}

// LoadRegistry: POST /api/v1/picking/registry/load — тот же файл после подтверждения оператора:
// сверка повторяется по свежему состоянию и пишется одной транзакцией.
func (h *PickingHandler) LoadRegistry(w http.ResponseWriter, r *http.Request) {
	h.registry(w, r, true)
}

func (h *PickingHandler) registry(w http.ResponseWriter, r *http.Request, write bool) {
	r.Body = http.MaxBytesReader(w, r.Body, maxImportUpload)
	file, header, err := r.FormFile("file")
	if err != nil {
		writeError(w, http.StatusBadRequest, "ожидается multipart-форма с файлом в поле 'file'")
		return
	}
	defer func() { _ = file.Close() }()
	code := strings.TrimSpace(r.FormValue("warehouse_code"))
	if code == "" {
		code = defaultWarehouseCode
	}

	var out *service.RegistryPreview
	if write {
		userID, _ := appmw.UserIDFromContext(r.Context())
		out, err = h.load.Load(r.Context(), code, header.Filename, userID, file)
	} else {
		out, err = h.load.Preview(r.Context(), code, file)
	}
	if err != nil {
		if errors.Is(err, service.ErrRegistryFile) {
			writeError(w, http.StatusUnprocessableEntity, err.Error())
			return
		}
		slog.Error("picking registry", "write", write, "error", err)
		writeError(w, http.StatusInternalServerError, "не удалось загрузить реестр")
		return
	}
	writeJSON(w, http.StatusOK, out)
}
