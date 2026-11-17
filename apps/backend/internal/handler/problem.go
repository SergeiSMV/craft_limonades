package handler

import (
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"slices"
	"strconv"
	"time"

	"github.com/go-chi/chi/v5"

	appmw "craftwms/internal/middleware"
	"craftwms/internal/model"
	"craftwms/internal/repository"
	"craftwms/internal/service"
)

// ProblemHandler - «Проблемы склада» в портале (P6-07-3): список и решение офиса.
type ProblemHandler struct {
	svc *service.ProblemService
}

// NewProblemHandler создаёт обработчик проблем склада.
func NewProblemHandler(svc *service.ProblemService) *ProblemHandler {
	return &ProblemHandler{svc: svc}
}

type problemItemResponse struct {
	GoodID         string `json:"good_id"`
	GoodCode       string `json:"good_code"`
	GoodName       string `json:"good_name"`
	ProductionDate string `json:"production_date"`
	Qty            string `json:"qty"`
	CellAddress    string `json:"cell_address"`
}

type problemResponse struct {
	ID          string    `json:"id"`
	Number      int64     `json:"number"` // номер для людей (ADHOC-55), префикс - у показа
	CreatedAt   time.Time `json:"created_at"`
	CreatedBy   string    `json:"created_by"`
	CellAddress string    `json:"cell_address"`
	LoadUnitID  string    `json:"load_unit_id,omitempty"`
	Reason      string    `json:"reason"`
	ReasonName  string    `json:"reason_name"` // название по справочнику (ADHOC-55)
	Comment     string    `json:"comment"`
	Mark        string    `json:"mark,omitempty"`
	// Marks - КИ марок ЧЗ проблемы (ADHOC-52); нет марок - пустой список.
	Marks         []string `json:"marks"`
	FromWarehouse string   `json:"from_warehouse"`
	ToWarehouse   string   `json:"to_warehouse"`
	// Пересорт (ADHOC-53): прежний товар и перепривязанный ШК; у остальных причин поля нет.
	FromGood string                `json:"from_good,omitempty"`
	Barcode  string                `json:"barcode,omitempty"`
	Items    []problemItemResponse `json:"items"`
	// Варианты решения, которыми проблему можно решить сейчас, в порядке справочника (ADHOC-55).
	Resolutions []problemResolutionResponse `json:"resolutions"`
	// Decisions - действия этих вариантов: прежний бандл портала решает действием.
	Decisions           []string `json:"decisions"`
	SuggestedSupplierID string   `json:"suggested_supplier_id,omitempty"`

	Status   string `json:"status"`
	Decision string `json:"decision,omitempty"`
	// ResolutionName - выбранный вариант решения (ADHOC-55).
	ResolutionName string     `json:"resolution_name,omitempty"`
	DocNumber      string     `json:"doc_number,omitempty"`
	DocDate        string     `json:"doc_date,omitempty"`
	SupplierID     string     `json:"supplier_id,omitempty"`
	SupplierName   string     `json:"supplier_name,omitempty"`
	ReturnTaskNo   int64      `json:"return_task_number,omitempty"`
	ResolvedBy     string     `json:"resolved_by,omitempty"`
	ResolvedAt     *time.Time `json:"resolved_at,omitempty"`
	// Исполнение возврата (ADHOC-34): кто и когда отгрузил поставщику; нет - ещё не отгружен.
	ShippedBy string     `json:"shipped_by,omitempty"`
	ShippedAt *time.Time `json:"shipped_at,omitempty"`
	// ShipmentNumber - номер отгрузки возврата, «ВП» (ADHOC-55); нет - не отгружен.
	ShipmentNumber int64 `json:"shipment_number,omitempty"`
	// Photos - идентификаторы фото в порядке съёмки (ADHOC-45); снимок - отдельным запросом.
	Photos []string `json:"photos"`
}

func toProblemResponse(p model.Problem) problemResponse {
	items := make([]problemItemResponse, 0, len(p.Items))
	for _, it := range p.Items {
		items = append(items, problemItemResponse(it))
	}
	resolutions := make([]problemResolutionResponse, 0, len(p.Resolutions))
	decisions := []string{}
	for _, x := range p.Resolutions {
		resolutions = append(resolutions, problemResolutionResponse(x))
		if !slices.Contains(decisions, x.Action) {
			decisions = append(decisions, x.Action)
		}
	}
	return problemResponse{
		ID: p.ID, Number: p.Number, CreatedAt: p.CreatedAt, CreatedBy: p.CreatedByName, CellAddress: p.CellAddress,
		LoadUnitID: p.LoadUnitID, Reason: p.Reason, ReasonName: p.ReasonName, Comment: p.Comment, Mark: p.Mark,
		Marks:         orEmpty(p.Marks),
		FromWarehouse: p.FromWarehouse, ToWarehouse: p.ToWarehouse, FromGood: p.FromGoodName,
		Barcode: p.Barcode, Items: items,
		Resolutions: resolutions, Decisions: decisions, SuggestedSupplierID: p.SuggestedSupplierID,
		Status: p.Status, Decision: p.Decision, ResolutionName: p.ResolutionName, DocNumber: p.DocNumber, DocDate: p.DocDate,
		SupplierID: p.SupplierID, SupplierName: p.SupplierName, ReturnTaskNo: p.ReturnTaskNo,
		ResolvedBy: p.ResolvedByName, ResolvedAt: p.ResolvedAt,
		ShippedBy: p.ShippedByName, ShippedAt: p.ShippedAt, ShipmentNumber: p.ShipmentNumber, Photos: orEmpty(p.Photos),
	}
}

// orEmpty - пустой список вместо null: клиенту не нужно отличать «нет фото» или «нет марок»
// от «нет поля».
func orEmpty(ids []string) []string {
	if ids == nil {
		return []string{}
	}
	return ids
}

// List: GET /api/v1/problems?status=open|resolved - рабочий список: открытые сверху.
func (h *ProblemHandler) List(w http.ResponseWriter, r *http.Request) {
	items, err := h.svc.List(r.Context(), r.URL.Query().Get("status"))
	if errors.Is(err, service.ErrInvalidDecision) {
		writeError(w, http.StatusBadRequest, "статус - open или resolved")
		return
	}
	if err != nil {
		slog.ErrorContext(r.Context(), "problems failed", "error", err)
		writeError(w, http.StatusInternalServerError, "внутренняя ошибка")
		return
	}
	out := make([]problemResponse, 0, len(items))
	for _, p := range items {
		out = append(out, toProblemResponse(p))
	}
	writeJSON(w, http.StatusOK, out)
}

// Current: GET /api/v1/problems/current - открытые проблемы склада на ТСД (ADHOC-35), свежие
// первыми: вкладка «Текущие». Форма - та же, что у ленты решённых.
func (h *ProblemHandler) Current(w http.ResponseWriter, r *http.Request) {
	items, err := h.svc.Current(r.Context())
	if err != nil {
		slog.ErrorContext(r.Context(), "current problems failed", "error", err)
		writeError(w, http.StatusInternalServerError, "внутренняя ошибка")
		return
	}
	out := make([]problemResponse, 0, len(items))
	for _, p := range items {
		out = append(out, toProblemResponse(p))
	}
	writeJSON(w, http.StatusOK, out)
}

// Resolved: GET /api/v1/problems/resolved?from=&to=&before_resolved_at=&before_id=&limit= -
// лента «Завершённые» проблем на ТСД (ADHOC-34): только решённые офисом, свежие первыми.
func (h *ProblemHandler) Resolved(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	limit, _ := strconv.Atoi(q.Get("limit"))
	items, err := h.svc.Resolved(r.Context(), service.ResolvedQuery{
		From: q.Get("from"), To: q.Get("to"), BeforeResolvedAt: q.Get("before_resolved_at"),
		BeforeID: q.Get("before_id"), Limit: limit,
	})
	if errors.Is(err, service.ErrInvalidProblemFilter) {
		writeError(w, http.StatusBadRequest, "неверный фильтр")
		return
	}
	if err != nil {
		slog.ErrorContext(r.Context(), "resolved problems failed", "error", err)
		writeError(w, http.StatusInternalServerError, "внутренняя ошибка")
		return
	}
	out := make([]problemResponse, 0, len(items))
	for _, p := range items {
		out = append(out, toProblemResponse(p))
	}
	writeJSON(w, http.StatusOK, out)
}

// Resolve: POST /api/v1/problems/{id}/resolve {resolution_id, doc_number?, doc_date?,
// supplier_id?} - «Провести» решение офиса вариантом справочника (ADHOC-55). Прежний бандл
// портала шлёт `decision` - действие без варианта. 204 / 400 / 404 / 409.
func (h *ProblemHandler) Resolve(w http.ResponseWriter, r *http.Request) {
	var req struct {
		ResolutionID string `json:"resolution_id"`
		Decision     string `json:"decision"`
		DocNumber    string `json:"doc_number"`
		DocDate      string `json:"doc_date"`
		SupplierID   string `json:"supplier_id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "неверное тело запроса")
		return
	}
	userID, _ := appmw.UserIDFromContext(r.Context())
	err := h.svc.Resolve(r.Context(), model.ResolveProblemInput{
		ProblemID: chi.URLParam(r, "id"), Decision: req.Decision, DocNumber: req.DocNumber,
		DocDate: req.DocDate, SupplierID: req.SupplierID, ResolvedBy: userID, ResolutionID: req.ResolutionID,
	})
	if err != nil {
		problemError(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// problemError - ответ на ошибку решения; текст - для оператора портала.
func problemError(w http.ResponseWriter, r *http.Request, err error) {
	switch {
	case errors.Is(err, service.ErrInvalidProblemID), errors.Is(err, repository.ErrProblemNotFound):
		writeError(w, http.StatusNotFound, "проблема не найдена")
	case errors.Is(err, service.ErrInvalidDecision):
		writeError(w, http.StatusBadRequest, "для списания нужны номер и дата документа 1С, для возврата - поставщик")
	case errors.Is(err, repository.ErrDecisionNotAllowed):
		writeError(w, http.StatusBadRequest, "этот вариант решения недоступен при такой причине")
	case errors.Is(err, repository.ErrUnknownSupplier):
		writeError(w, http.StatusBadRequest, "поставщик не найден")
	case errors.Is(err, repository.ErrProblemResolved):
		writeError(w, http.StatusConflict, "по проблеме уже принято решение")
	case errors.Is(err, repository.ErrProblemGoodsMissing):
		writeError(w, http.StatusConflict,
			"товара проблемы нет на складе-метке: короб перевели или опустошили, россыпь разобрали или убрали в короб")
	default:
		slog.ErrorContext(r.Context(), "problem resolve failed", "error", err)
		writeError(w, http.StatusInternalServerError, "внутренняя ошибка")
	}
}
