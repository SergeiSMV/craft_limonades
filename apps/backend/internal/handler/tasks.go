package handler

import (
	"errors"
	"log/slog"
	"net/http"
	"strconv"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/shopspring/decimal"

	appmw "craftwms/internal/middleware"
	"craftwms/internal/model"
	"craftwms/internal/service"
)

// TaskHandler - задания для склада на ТСД (P5-02-1): текущие, карточка, взятие и отказ,
// лента «Завершённые». Сотруднику: задания выполняет кладовщик.
type TaskHandler struct {
	svc *service.TaskService
}

// NewTaskHandler создаёт обработчик заданий.
func NewTaskHandler(svc *service.TaskService) *TaskHandler {
	return &TaskHandler{svc: svc}
}

// productionDateLayout - дата партии в транспорте: DD-MM-YYYY, как на упаковке (и в приёмке).
const productionDateLayout = "02-01-2006"

type taskGoodResponse struct {
	ID   string `json:"id"`
	Code string `json:"code"`
	Name string `json:"name"`
	Uom  string `json:"uom"`
}

type taskContentResponse struct {
	Good           taskGoodResponse `json:"good"`
	ProductionDate string           `json:"production_date"`
	Qty            decimal.Decimal  `json:"qty"`
}

// taskItemResponse - позиция задания: короб (load_unit_id + contents) ЛИБО россыпь (good …).
type taskItemResponse struct {
	LineNo         int                   `json:"line_no"`
	LoadUnitID     *string               `json:"load_unit_id,omitempty"`
	Contents       []taskContentResponse `json:"contents,omitempty"`
	Good           *taskGoodResponse     `json:"good,omitempty"`
	ProductionDate *string               `json:"production_date,omitempty"`
	Qty            *decimal.Decimal      `json:"qty,omitempty"`
	Remaining      *decimal.Decimal      `json:"remaining,omitempty"`
	Placed         bool                  `json:"placed"` // у возврата - «отгружено»
	// Короб ЧЗ (CZ-06): код `00`+SSCC - короб узнаётся сканом этикетки ЧЗ.
	CZCode *string `json:"cz_code,omitempty"`
	// Марки позиции возврата россыпью (CZ-06, долг 30): отгрузка - сканом каждой.
	Marks []string `json:"marks,omitempty"`
	// Позиция возврата (ADHOC-31): проблема-основание и где лежит сейчас.
	ProblemID *string `json:"problem_id,omitempty"`
	Cell      string  `json:"cell,omitempty"`
}

type taskResponse struct {
	ID          string  `json:"id"`
	Number      int64   `json:"number"`
	Kind        string  `json:"kind"`
	Status      string  `json:"status"` // как его видит запросивший: чужое зависшее - new
	WarehouseID string  `json:"warehouse_id"`
	ReceiptID   *string `json:"receipt_id"`
	Supplier    string  `json:"supplier"`    // пусто - без поставщика
	ReceivedAt  *string `json:"received_at"` // RFC3339
	DocNumber   *string `json:"doc_number"`  // накладная приёмки (ADHOC-23); null - нет
	DocDate     *string `json:"doc_date"`    // DD-MM-YYYY
	// Проблема-основание размещения по решению «разместить» (ADHOC-55); нет - основание другое.
	Problem      *taskProblemResponse `json:"problem,omitempty"`
	AssigneeName string               `json:"assignee_name"`
	TakenAt      *string              `json:"taken_at"`
	CreatedAt    string               `json:"created_at"`
	// Пересчёт задания вида stocktake (P10-03); null - у других видов.
	StocktakeID *string                `json:"stocktake_id"`
	Stocktake   *taskStocktakeResponse `json:"stocktake,omitempty"` // ход пересчёта (P10-04)
	// Заказ сборки задания «вернуть на места» (P9-07-1); нет - у других видов.
	Picking *taskPickingResponse `json:"picking,omitempty"`
	Items   []taskItemResponse   `json:"items"`
}

// taskPickingResponse - заказ-основание возврата на места: номер сборки, накладная и заказ 1С,
// удалён ли, когда изменён реестром, сколько осталось вернуть.
type taskPickingResponse struct {
	OrderID       string          `json:"order_id"`
	Number        int64           `json:"number"`
	InvoiceNumber string          `json:"invoice_number"`
	OrderNumber   string          `json:"order_number"`
	Client        string          `json:"client"`
	Deleted       bool            `json:"deleted"`
	ChangedAt     *string         `json:"changed_at"` // RFC3339
	Left          decimal.Decimal `json:"left"`
}

func toTaskPicking(p *model.TaskPickingInfo) *taskPickingResponse {
	if p == nil {
		return nil
	}
	return &taskPickingResponse{OrderID: p.OrderID, Number: p.Number, InvoiceNumber: p.InvoiceNumber,
		OrderNumber: p.OrderNumber, Client: p.Client, Deleted: p.Deleted,
		ChangedAt: formatTimePtr(p.ChangedAt), Left: p.Left}
}

// taskProblemResponse - проблема-основание задания на размещение (ADHOC-55).
type taskProblemResponse struct {
	ID     string `json:"id"`
	Number int64  `json:"number"`
}

func toTaskProblem(p *model.TaskProblemInfo) *taskProblemResponse {
	if p == nil {
		return nil
	}
	return &taskProblemResponse{ID: p.ID, Number: p.Number}
}

type taskStocktakeResponse struct {
	Number    int64  `json:"number"`
	ScopeKind string `json:"scope_kind"`
	CreatedBy string `json:"created_by"`
	Cells     int    `json:"cells"`
	Counted   int    `json:"counted"`
}

type taskSessionLineResponse struct {
	LoadUnitID     *string           `json:"load_unit_id,omitempty"`
	Good           *taskGoodResponse `json:"good,omitempty"`
	ProductionDate *string           `json:"production_date,omitempty"`
	Qty            *decimal.Decimal  `json:"qty,omitempty"`
	From           string            `json:"from"`
	To             string            `json:"to"`
}

type taskUserResponse struct {
	ID       string `json:"id"`
	FullName string `json:"full_name"`
}

type taskSessionResponse struct {
	PutawayID string                    `json:"putaway_id"`
	User      taskUserResponse          `json:"user"`
	PostedAt  string                    `json:"posted_at"`
	Lines     []taskSessionLineResponse `json:"lines"`
}

// taskEventResponse - запись журнала задания. user - пусто у системных событий.
type taskEventResponse struct {
	Event     string  `json:"event"`
	User      string  `json:"user"`
	PrevUser  string  `json:"prev_user,omitempty"`
	PutawayID *string `json:"putaway_id,omitempty"`
	Cell      string  `json:"cell,omitempty"` // адрес подсчитанной ячейки пересчёта (ADHOC-58)
	At        string  `json:"at"`
}

type taskDetailResponse struct {
	taskResponse
	Sessions []taskSessionResponse `json:"sessions"`
	Events   []taskEventResponse   `json:"events"`
}

type completedTaskResponse struct {
	ID          string             `json:"id"`
	Number      int64              `json:"number"`
	Kind        string             `json:"kind"`
	Supplier    string             `json:"supplier"`
	DocNumber   *string            `json:"doc_number"`   // накладная приёмки (ADHOC-23); null - нет
	DocDate     *string            `json:"doc_date"`     // DD-MM-YYYY
	CompletedAt string             `json:"completed_at"` // RFC3339Nano - он же курсор подгрузки
	Executors   []taskUserResponse `json:"executors"`
	Sessions    int                `json:"sessions"`
	// Проблема-основание размещения (ADHOC-55); нет - основание другое.
	Problem *taskProblemResponse `json:"problem,omitempty"`
	// Пересчёт задания вида stocktake (ADHOC-58); у пересчёта sessions - подсчитанные ячейки.
	Stocktake *taskStocktakeResponse `json:"stocktake,omitempty"`
	// Заказ сборки задания «вернуть на места» (P9-07-1).
	Picking *taskPickingResponse `json:"picking,omitempty"`
}

// Current: GET /api/v1/tasks - текущие задания: пул и свои взятые, с позициями.
// ТСД кладёт ответ в кэш: по нему задание выполняется без связи.
func (h *TaskHandler) Current(w http.ResponseWriter, r *http.Request) {
	userID, _ := appmw.UserIDFromContext(r.Context())
	tasks, err := h.svc.Current(r.Context(), userID)
	if err != nil {
		slog.ErrorContext(r.Context(), "tasks current failed", "error", err)
		writeError(w, http.StatusInternalServerError, "внутренняя ошибка")
		return
	}
	out := make([]taskResponse, 0, len(tasks))
	for _, t := range tasks {
		out = append(out, toTaskResponse(t))
	}
	writeJSON(w, http.StatusOK, out)
}

// Get: GET /api/v1/tasks/{id} - карточка задания: позиции, заходы, журнал событий. 200 / 404.
func (h *TaskHandler) Get(w http.ResponseWriter, r *http.Request) {
	userID, _ := appmw.UserIDFromContext(r.Context())
	d, err := h.svc.Detail(r.Context(), chi.URLParam(r, "id"), userID)
	if errors.Is(err, model.ErrTaskNotFound) {
		writeError(w, http.StatusNotFound, "задание не найдено")
		return
	}
	if err != nil {
		slog.ErrorContext(r.Context(), "task detail failed", "error", err)
		writeError(w, http.StatusInternalServerError, "внутренняя ошибка")
		return
	}
	out := taskDetailResponse{
		taskResponse: toTaskResponse(d.Task),
		Sessions:     []taskSessionResponse{},
		Events:       []taskEventResponse{},
	}
	for _, ev := range d.Events {
		out.Events = append(out.Events, taskEventResponse{
			Event: ev.Event, User: ev.UserName, PrevUser: ev.PrevUserName,
			PutawayID: ev.PutawayID, Cell: ev.Cell, At: ev.At.Format(time.RFC3339),
		})
	}
	for _, s := range d.Sessions {
		sr := taskSessionResponse{
			PutawayID: s.PutawayID,
			User:      taskUserResponse(s.User),
			PostedAt:  s.PostedAt.Format(time.RFC3339),
		}
		for _, ln := range s.Lines {
			sr.Lines = append(sr.Lines, taskSessionLineResponse{
				LoadUnitID:     ln.LoadUnitID,
				Good:           toTaskGood(ln.Good),
				ProductionDate: formatProductionDate(ln.ProductionDate),
				Qty:            ln.Qty,
				From:           ln.FromAddress,
				To:             ln.ToAddress,
			})
		}
		out.Sessions = append(out.Sessions, sr)
	}
	writeJSON(w, http.StatusOK, out)
}

// Take: POST /api/v1/tasks/{id}/take - взять в работу. 204 / 404 / 409 (у другого или выполнено).
// Повтор своим исполнителем - тоже 204.
func (h *TaskHandler) Take(w http.ResponseWriter, r *http.Request) {
	userID, _ := appmw.UserIDFromContext(r.Context())
	h.writeTaskResult(w, r, h.svc.Take(r.Context(), chi.URLParam(r, "id"), userID), "take")
}

// Release: POST /api/v1/tasks/{id}/release - отказаться: задание уходит в пул. 204 / 404 / 409.
func (h *TaskHandler) Release(w http.ResponseWriter, r *http.Request) {
	userID, _ := appmw.UserIDFromContext(r.Context())
	h.writeTaskResult(w, r, h.svc.Release(r.Context(), chi.URLParam(r, "id"), userID), "release")
}

func (h *TaskHandler) writeTaskResult(w http.ResponseWriter, r *http.Request, err error, action string) {
	switch {
	case err == nil:
		w.WriteHeader(http.StatusNoContent)
	case errors.Is(err, model.ErrTaskNotFound):
		writeError(w, http.StatusNotFound, "задание не найдено")
	case errors.Is(err, model.ErrTaskTaken):
		writeError(w, http.StatusConflict, "задание уже взял другой сотрудник")
	case errors.Is(err, model.ErrTaskDone):
		writeError(w, http.StatusConflict, "задание уже выполнено")
	default:
		slog.ErrorContext(r.Context(), "task action failed", "action", action, "error", err)
		writeError(w, http.StatusInternalServerError, "внутренняя ошибка")
	}
}

// Completed: GET /api/v1/tasks/completed - лента «Завершённые», свежие сверху.
//
// Параметры: from, to (YYYY-MM-DD, по времени склада; to включается), executor (id), kind,
// before_completed_at + before_id (курсор: последняя показанная запись), limit. 200 / 400.
func (h *TaskHandler) Completed(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	limit, _ := strconv.Atoi(q.Get("limit"))
	items, err := h.svc.Completed(r.Context(), service.CompletedQuery{
		From: q.Get("from"), To: q.Get("to"), ExecutorID: q.Get("executor"), Kind: q.Get("kind"),
		BeforeCompletedAt: q.Get("before_completed_at"), BeforeID: q.Get("before_id"), Limit: limit,
	})
	if errors.Is(err, model.ErrInvalidTaskFilter) {
		writeError(w, http.StatusBadRequest, "неверный фильтр")
		return
	}
	if err != nil {
		slog.ErrorContext(r.Context(), "tasks completed failed", "error", err)
		writeError(w, http.StatusInternalServerError, "внутренняя ошибка")
		return
	}
	out := make([]completedTaskResponse, 0, len(items))
	for _, c := range items {
		ex := make([]taskUserResponse, 0, len(c.Executors))
		for _, u := range c.Executors {
			ex = append(ex, taskUserResponse(u))
		}
		out = append(out, completedTaskResponse{
			ID: c.ID, Number: c.Number, Kind: c.Kind, Supplier: c.SupplierName,
			DocNumber: c.DocNumber, DocDate: formatProductionDate(c.DocDate),
			CompletedAt: c.CompletedAt.Format(time.RFC3339Nano), Executors: ex, Sessions: c.Sessions,
			Problem: toTaskProblem(c.Problem), Stocktake: toTaskStocktake(c.Stocktake),
			Picking: toTaskPicking(c.Picking),
		})
	}
	writeJSON(w, http.StatusOK, out)
}

// Executors: GET /api/v1/tasks/executors - варианты фильтра ленты по исполнителю.
func (h *TaskHandler) Executors(w http.ResponseWriter, r *http.Request) {
	users, err := h.svc.Executors(r.Context())
	if err != nil {
		slog.ErrorContext(r.Context(), "tasks executors failed", "error", err)
		writeError(w, http.StatusInternalServerError, "внутренняя ошибка")
		return
	}
	out := make([]taskUserResponse, 0, len(users))
	for _, u := range users {
		out = append(out, taskUserResponse(u))
	}
	writeJSON(w, http.StatusOK, out)
}

// toTaskStocktake - пересчёт задания для ответа; nil - задание не пересчёт.
func toTaskStocktake(st *model.TaskStocktakeInfo) *taskStocktakeResponse {
	if st == nil {
		return nil
	}
	return &taskStocktakeResponse{Number: st.Number, ScopeKind: st.ScopeKind,
		CreatedBy: st.CreatedBy, Cells: st.Cells, Counted: st.Counted}
}

func toTaskResponse(t model.Task) taskResponse {
	out := taskResponse{
		ID: t.ID, Number: t.Number, Kind: t.Kind, Status: t.Status, WarehouseID: t.WarehouseID,
		ReceiptID: t.ReceiptID, Supplier: t.SupplierName, ReceivedAt: formatTimePtr(t.ReceivedAt),
		DocNumber: t.DocNumber, DocDate: formatProductionDate(t.DocDate), Problem: toTaskProblem(t.Problem),
		AssigneeName: t.AssigneeName, TakenAt: formatTimePtr(t.TakenAt),
		CreatedAt: t.CreatedAt.Format(time.RFC3339), StocktakeID: t.StocktakeID, Items: []taskItemResponse{},
	}
	out.Stocktake = toTaskStocktake(t.Stocktake)
	out.Picking = toTaskPicking(t.Picking)
	for _, it := range t.Items {
		ir := taskItemResponse{LineNo: it.LineNo, LoadUnitID: it.LoadUnitID, Placed: it.Placed,
			ProblemID: it.ProblemID, Cell: it.CellAddress, CZCode: it.CZCode, Marks: it.Marks}
		if it.LoadUnitID != nil {
			for _, c := range it.Contents {
				ir.Contents = append(ir.Contents, taskContentResponse{
					Good:           *toTaskGood(&c.Good),
					ProductionDate: c.ProductionDate.Format(productionDateLayout),
					Qty:            c.Qty,
				})
			}
		} else {
			qty, left := it.Qty, it.Remaining
			ir.Good = toTaskGood(it.Good)
			ir.ProductionDate = formatProductionDate(it.ProductionDate)
			ir.Qty, ir.Remaining = &qty, &left
		}
		out.Items = append(out.Items, ir)
	}
	return out
}

func toTaskGood(g *model.TaskGood) *taskGoodResponse {
	if g == nil {
		return nil
	}
	return &taskGoodResponse{ID: g.ID, Code: g.Code, Name: g.Name, Uom: g.Uom}
}

func formatProductionDate(d *time.Time) *string {
	if d == nil {
		return nil
	}
	s := d.Format(productionDateLayout)
	return &s
}
