package handler

import (
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"

	appmw "craftwms/internal/middleware"
	"craftwms/internal/model"
	"craftwms/internal/repository"
	"craftwms/internal/service"
)

// xlsxContentType — MIME .xlsx (OOXML).
const xlsxContentType = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"

// DocumentHandler — рабочий список документов оператора (P3-02). Право — по виду документа и
// действию (ADHOC-50): «Приход: скачивать», «Перемещение: проводить» и т. п.; маршрут пускает
// любого с правом хоть на один вид, обработчик уточняет.
type DocumentHandler struct {
	svc *service.DocumentService
}

// NewDocumentHandler создаёт обработчик документов.
func NewDocumentHandler(svc *service.DocumentService) *DocumentHandler {
	return &DocumentHandler{svc: svc}
}

// documentItemResponse — элемент списка документов.
type documentItemResponse struct {
	ID            string `json:"id"`
	Kind          string `json:"kind"`
	WarehouseCode string `json:"warehouse_code"`
	WarehouseName string `json:"warehouse_name"`
	// Supplier, DocNumber, DocDate — поставщик и его накладная: у «Поступления» — свои,
	// у «Движения» размещения — приёмки-основания. Пусто — нет.
	Supplier   string `json:"supplier"`
	DocNumber  string `json:"doc_number"`
	DocDate    string `json:"doc_date"`    // DD-MM-YYYY
	Operation  string `json:"operation"`   // операция «Движения» (`putaway`, `move`); пусто — другая форма
	TaskNumber int64  `json:"task_number"` // задание-основание «Движения»; 0 — нет
	// ProblemNumber — проблема склада, по решению которой заведено задание (ADHOC-55); 0 — нет.
	ProblemNumber int64 `json:"problem_number"`
	// Number — номер документа, счётчик формы; SourceNumber — номер операции-источника
	// (у «Инвентаризации» — stocktake_number), 0 — документ до ADHOC-55 (ADHOC-55).
	Number       int64 `json:"number"`
	SourceNumber int64 `json:"source_number"`
	// Пересчёт «Инвентаризации» (P10-05); 0 — другая форма.
	StocktakeNumber int64   `json:"stocktake_number"`
	Executor        string  `json:"executor"`   // кто выполнил операцию; пусто — неизвестно
	CreatedAt       string  `json:"created_at"` // RFC3339
	LinesCount      int     `json:"lines_count"`
	Status          string  `json:"status"`
	DownloadedAt    *string `json:"downloaded_at"` // RFC3339 или null
	DoneAt          *string `json:"done_at"`       // RFC3339 или null
}

// List: GET /api/v1/documents — рабочий список: сначала необработанные, свежие сверху.
// Необязательный ?kind= оставляет одну форму (`stock_entry`, `receipt`, `movement`, `stocktake`): у каждой в портале
// своя вкладка. Незнакомая форма — пустой список, а не ошибка: фильтр, ничего не нашедший.
//
// Права: с ?kind= — любое право на этот вид (смотреть, скачивать, проводить: без списка
// последние два бессмысленны), иначе 403; без него — только такие виды. История документа —
// право «смотреть».
func (h *DocumentHandler) List(w http.ResponseWriter, r *http.Request) {
	kind := strings.TrimSpace(r.URL.Query().Get("kind"))
	access, _ := appmw.AccessFromContext(r.Context())
	if kind != "" && !canListDocuments(access, kind) {
		writeError(w, http.StatusForbidden, "нет права смотреть эти документы")
		return
	}
	docs, err := h.svc.List(r.Context(), kind)
	if err != nil {
		slog.ErrorContext(r.Context(), "documents list failed", "error", err)
		writeError(w, http.StatusInternalServerError, "внутренняя ошибка")
		return
	}
	out := make([]documentItemResponse, 0, len(docs))
	for _, d := range docs {
		if !canListDocuments(access, d.Kind) {
			continue
		}
		out = append(out, documentItemResponse{
			ID:              d.ID,
			Kind:            d.Kind,
			WarehouseCode:   d.WarehouseCode,
			WarehouseName:   d.WarehouseName,
			Supplier:        d.Supplier,
			DocNumber:       d.DocNumber,
			DocDate:         isoToTransportDate(d.DocDate),
			Operation:       d.Operation,
			TaskNumber:      d.TaskNumber,
			ProblemNumber:   d.ProblemNumber,
			Number:          d.Number,
			SourceNumber:    d.SourceNumber,
			StocktakeNumber: d.StocktakeNumber,
			Executor:        d.Executor,
			CreatedAt:       d.CreatedAt.Format(time.RFC3339),
			LinesCount:      d.LinesCount,
			Status:          d.Status,
			DownloadedAt:    formatTimePtr(d.DownloadedAt),
			DoneAt:          formatTimePtr(d.DoneAt),
		})
	}
	writeJSON(w, http.StatusOK, out)
}

// File: GET /api/v1/documents/{id}/file.xlsx — .xlsx документа; попутно отмечает скачивание.
// 200 .xlsx (attachment) / 404 (нет документа).
func (h *DocumentHandler) File(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	if !h.allowed(w, r, id, model.DocDownload) {
		return
	}
	userID, _ := appmw.UserIDFromContext(r.Context())
	data, filename, err := h.svc.File(r.Context(), id, userID)
	switch {
	case errors.Is(err, repository.ErrDocumentNotFound):
		writeError(w, http.StatusNotFound, "документ не найден")
		return
	case err != nil:
		slog.ErrorContext(r.Context(), "document file failed", "document", id, "error", err)
		writeError(w, http.StatusInternalServerError, "внутренняя ошибка")
		return
	}

	w.Header().Set("Content-Type", xlsxContentType)
	w.Header().Set("Content-Disposition", fmt.Sprintf(`attachment; filename="%s"`, filename))
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(data)
}

// Done: POST /api/v1/documents/{id}/done — «Выполнено»: документ занесён в 1С.
// 204 / 404. Повтор идемпотентен и тоже отвечает 204: оператор нажал дважды — это не ошибка.
func (h *DocumentHandler) Done(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	if !h.allowed(w, r, id, model.DocPost) {
		return
	}
	userID, _ := appmw.UserIDFromContext(r.Context())
	err := h.svc.MarkDone(r.Context(), id, userID)
	switch {
	case errors.Is(err, service.ErrEmptyDocumentID):
		writeError(w, http.StatusBadRequest, "не указан документ")
		return
	case errors.Is(err, repository.ErrDocumentNotFound):
		writeError(w, http.StatusNotFound, "документ не найден")
		return
	case err != nil:
		slog.ErrorContext(r.Context(), "document done failed", "document", id, "error", err)
		writeError(w, http.StatusInternalServerError, "внутренняя ошибка")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// documentEventResponse — запись журнала документа.
type documentEventResponse struct {
	Event     string `json:"event"`
	UserName  string `json:"user_name"` // «» — событие системное или автор не сохранился
	Details   string `json:"details"`   // причина ошибки для generation_failed
	CreatedAt string `json:"created_at"`
}

// Events: GET /api/v1/documents/{id}/events — история документа: сформирован, скачан, выполнен.
// 200 / 404 (нет документа).
func (h *DocumentHandler) Events(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	if !h.allowed(w, r, id, model.DocView) {
		return
	}
	events, err := h.svc.Events(r.Context(), id)
	switch {
	case errors.Is(err, repository.ErrDocumentNotFound):
		writeError(w, http.StatusNotFound, "документ не найден")
		return
	case err != nil:
		slog.ErrorContext(r.Context(), "document events failed", "document", id, "error", err)
		writeError(w, http.StatusInternalServerError, "внутренняя ошибка")
		return
	}
	out := make([]documentEventResponse, 0, len(events))
	for _, e := range events {
		out = append(out, documentEventResponse{
			Event:     e.Event,
			UserName:  e.UserName,
			Details:   e.Details,
			CreatedAt: e.CreatedAt.Format(time.RFC3339),
		})
	}
	writeJSON(w, http.StatusOK, out)
}

// formatTimePtr — необязательная отметка времени в RFC3339; nil остаётся null в JSON.
func formatTimePtr(t *time.Time) *string {
	if t == nil {
		return nil
	}
	s := t.Format(time.RFC3339)
	return &s
}

// isoToTransportDate переводит дату снимка YYYY-MM-DD в транспортный вид DD-MM-YYYY, как у дат
// партий; пустая или неразборчивая — пусто.
func isoToTransportDate(iso string) string {
	d, err := time.Parse("2006-01-02", iso)
	if err != nil {
		return ""
	}
	return d.Format(productionDateLayout)
}

// allowed — есть ли право на действие [a] с документом [id] (ADHOC-50); нет — ответ уже
// записан: 404 — нет документа, 403 — нет права.
func (h *DocumentHandler) allowed(w http.ResponseWriter, r *http.Request, id string, a model.DocumentAction) bool {
	kind, err := h.svc.Kind(r.Context(), id)
	switch {
	case errors.Is(err, repository.ErrDocumentNotFound):
		writeError(w, http.StatusNotFound, "документ не найден")
		return false
	case err != nil:
		slog.ErrorContext(r.Context(), "document kind failed", "document", id, "error", err)
		writeError(w, http.StatusInternalServerError, "внутренняя ошибка")
		return false
	}
	access, _ := appmw.AccessFromContext(r.Context())
	if !access.Can(model.DocumentRight(kind, a)) {
		writeError(w, http.StatusForbidden, "нет права на это действие с документом")
		return false
	}
	return true
}

// canListDocuments — видит ли пользователь документы вида kind в списке: любое право на вид.
func canListDocuments(a model.Access, kind string) bool {
	return a.CanAny(model.DocumentRight(kind, model.DocView), model.DocumentRight(kind, model.DocDownload),
		model.DocumentRight(kind, model.DocPost))
}
