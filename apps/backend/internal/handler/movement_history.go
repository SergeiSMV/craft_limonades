package handler

import (
	"errors"
	"log/slog"
	"net/http"
	"strconv"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/shopspring/decimal"

	"craftwms/internal/model"
	"craftwms/internal/repository"
	"craftwms/internal/service"
)

// MovementHistoryHandler — история перемещений на ТСД (ADHOC-28): лента «Завершённые» в разделе
// «Перемещение» и запись со строками. Сотруднику: кладовщик видит перемещения всего склада.
type MovementHistoryHandler struct {
	svc *service.MovementHistoryService
}

// NewMovementHistoryHandler создаёт обработчик истории перемещений.
func NewMovementHistoryHandler(svc *service.MovementHistoryService) *MovementHistoryHandler {
	return &MovementHistoryHandler{svc: svc}
}

// movementRecordResponse — запись ленты.
type movementRecordResponse struct {
	ID        string           `json:"id"`
	Kind      string           `json:"kind"`      // move | replenish
	PostedAt  string           `json:"posted_at"` // RFC3339Nano: и показ, и курсор подгрузки
	Executor  taskUserResponse `json:"executor"`
	LoadUnits int              `json:"load_units"` // строк «короб целиком»
	Goods     int              `json:"goods"`      // строк товара
}

// movementPlaceResponse — место строки: россыпь ячейки или короб в ней. Тот же вид, что место
// в строке сеанса перемещения на ТСД: история показывается теми же словами.
type movementPlaceResponse struct {
	CellID      string  `json:"cell_id"`
	CellAddress string  `json:"cell_address"`
	LoadUnitID  *string `json:"load_unit_id,omitempty"`
}

// movementLineResponse — строка записи: ГЕ целиком (load_unit_id) ЛИБО товар (good …).
type movementLineResponse struct {
	LoadUnitID     *string               `json:"load_unit_id,omitempty"`
	Good           *taskGoodResponse     `json:"good,omitempty"`
	ProductionDate *string               `json:"production_date,omitempty"` // DD-MM-YYYY
	Qty            *decimal.Decimal      `json:"qty,omitempty"`
	From           movementPlaceResponse `json:"from"`
	To             movementPlaceResponse `json:"to"`
}

type movementDetailResponse struct {
	movementRecordResponse
	Lines []movementLineResponse `json:"lines"`
}

func toMovementRecordResponse(r model.MovementRecord) movementRecordResponse {
	return movementRecordResponse{
		ID: r.ID, Kind: r.Kind, PostedAt: r.PostedAt.Format(time.RFC3339Nano),
		Executor: taskUserResponse(r.Executor), LoadUnits: r.LoadUnits, Goods: r.Goods,
	}
}

// List: GET /api/v1/movements — лента истории, свежие сверху.
//
// Параметры: from, to (YYYY-MM-DD, по времени склада; to включается), executor (id),
// before_posted_at + before_id (курсор: последняя показанная запись), limit. 200 / 400.
func (h *MovementHistoryHandler) List(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	limit, _ := strconv.Atoi(q.Get("limit"))
	items, err := h.svc.List(r.Context(), service.MovementHistoryQuery{
		From: q.Get("from"), To: q.Get("to"), ExecutorID: q.Get("executor"),
		BeforePostedAt: q.Get("before_posted_at"), BeforeID: q.Get("before_id"), Limit: limit,
	})
	if errors.Is(err, service.ErrInvalidMovementFilter) {
		writeError(w, http.StatusBadRequest, "неверный фильтр")
		return
	}
	if err != nil {
		slog.ErrorContext(r.Context(), "movement history failed", "error", err)
		writeError(w, http.StatusInternalServerError, "внутренняя ошибка")
		return
	}
	out := make([]movementRecordResponse, 0, len(items))
	for _, it := range items {
		out = append(out, toMovementRecordResponse(it))
	}
	writeJSON(w, http.StatusOK, out)
}

// Executors: GET /api/v1/movements/executors — варианты фильтра ленты по исполнителю.
func (h *MovementHistoryHandler) Executors(w http.ResponseWriter, r *http.Request) {
	users, err := h.svc.Executors(r.Context())
	if err != nil {
		slog.ErrorContext(r.Context(), "movement executors failed", "error", err)
		writeError(w, http.StatusInternalServerError, "внутренняя ошибка")
		return
	}
	out := make([]taskUserResponse, 0, len(users))
	for _, u := range users {
		out = append(out, taskUserResponse(u))
	}
	writeJSON(w, http.StatusOK, out)
}

// Get: GET /api/v1/movements/{id} — запись со строками по порядку проведения. 200 / 404.
func (h *MovementHistoryHandler) Get(w http.ResponseWriter, r *http.Request) {
	d, err := h.svc.Get(r.Context(), chi.URLParam(r, "id"))
	if errors.Is(err, repository.ErrMovementNotFound) {
		writeError(w, http.StatusNotFound, "перемещение не найдено")
		return
	}
	if err != nil {
		slog.ErrorContext(r.Context(), "movement get failed", "error", err)
		writeError(w, http.StatusInternalServerError, "внутренняя ошибка")
		return
	}
	out := movementDetailResponse{
		movementRecordResponse: toMovementRecordResponse(d.MovementRecord),
		Lines:                  make([]movementLineResponse, 0, len(d.Lines)),
	}
	for _, l := range d.Lines {
		line := movementLineResponse{
			LoadUnitID:     l.LoadUnitID,
			ProductionDate: formatProductionDate(l.ProductionDate),
			Qty:            l.Qty,
			From:           movementPlaceResponse{CellID: l.FromCellID, CellAddress: l.FromCellAddress, LoadUnitID: l.FromLoadUnitID},
			To:             movementPlaceResponse{CellID: l.ToCellID, CellAddress: l.ToCellAddress, LoadUnitID: l.ToLoadUnitID},
		}
		if l.GoodID != nil {
			line.Good = &taskGoodResponse{ID: *l.GoodID, Code: deref(l.GoodCode), Name: deref(l.GoodName), Uom: deref(l.Uom)}
		}
		out.Lines = append(out.Lines, line)
	}
	writeJSON(w, http.StatusOK, out)
}

// deref — значение необязательной строки справочника; nil — пусто.
func deref(s *string) string {
	if s == nil {
		return ""
	}
	return *s
}
