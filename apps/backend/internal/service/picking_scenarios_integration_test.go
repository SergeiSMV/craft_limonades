package service

import (
	"bytes"
	"context"
	"errors"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/shopspring/decimal"

	"craftwms/internal/model"
	"craftwms/internal/repository"
	"craftwms/internal/testutil"
)

// P9-09D: сценарные тесты сборки по живой базе - так, как её проходят офис и склад: оператор
// загружает «Реестр» 1С файлом, кладовщик берёт заказ, собирает по подбору в короб отгрузки,
// завершает и отгружает, оператор видит итог и сверку с 1С в портале. Отдельные шаги и отказы
// покрыты тестами задач P9-01…P9-08; здесь - их стык.

// pickEnv — склад для сценариев: две ячейки хранения, лимонад двумя партиями, оператор и два
// кладовщика, сервисы так, как их собирает main.
type pickEnv struct {
	t      *testing.T
	ctx    context.Context
	pool   *pgxpool.Pool
	load   *PickingLoadService
	task   *PickingTaskService
	portal *PickingPortalService
	ops    *repository.OperationsRepository

	cellA, cellB     string
	lemon            string
	oldB, newA       string // партии 01.09.2026 и 01.10.2026
	main             string // внутренний склад «Основной»
	office, ann, bob string
}

func newPickEnv(t *testing.T) *pickEnv {
	t.Helper()
	pool := testutil.StartPostgres(t)
	e := &pickEnv{t: t, ctx: context.Background(), pool: pool}
	wh := e.scan(`INSERT INTO warehouses (code,name) VALUES ('SHB','Шабулина') RETURNING id::text`)
	e.cellA = e.scan(`INSERT INTO cells (warehouse_id,address) VALUES ($1,'A-1') RETURNING id::text`, wh)
	e.cellB = e.scan(`INSERT INTO cells (warehouse_id,address) VALUES ($1,'B-1') RETURNING id::text`, wh)
	e.office = e.scan(`INSERT INTO users (login,password_hash,full_name) VALUES ('90000061','x','Оператор') RETURNING id::text`)
	e.ann = e.scan(`INSERT INTO users (login,password_hash,full_name) VALUES ('90000062','x','Анна') RETURNING id::text`)
	e.bob = e.scan(`INSERT INTO users (login,password_hash,full_name) VALUES ('90000063','x','Борис') RETURNING id::text`)
	// Код как его пишет импорт номенклатуры .xls - без ведущих нулей.
	e.lemon = e.scan(`INSERT INTO goods (code,name,uom) VALUES ('16147','Лимонад','шт') RETURNING id::text`)
	e.oldB = e.scan(`INSERT INTO batches (good_id,production_date) VALUES ($1,'2026-09-01') RETURNING id::text`, e.lemon)
	e.newA = e.scan(`INSERT INTO batches (good_id,production_date) VALUES ($1,'2026-10-01') RETURNING id::text`, e.lemon)
	e.main = e.scan(`SELECT id::text FROM internal_warehouses WHERE is_default`)

	pk := repository.NewPickingRepository(pool)
	e.load = NewPickingLoadService(NewPickingRegistryService(repository.NewGoodsRepository(pool)),
		pk, repository.NewWarehouseRepository(pool))
	e.task = NewPickingTaskService(pk)
	e.portal = NewPickingPortalService(pk, repository.NewWarehouseRepository(pool))
	e.ops = repository.NewOperationsRepository(pool)
	return e
}

func (e *pickEnv) scan(sql string, args ...any) string {
	e.t.Helper()
	var v string
	if err := e.pool.QueryRow(e.ctx, sql, args...).Scan(&v); err != nil {
		e.t.Fatalf("%s: %v", sql, err)
	}
	return v
}

// stock кладёт лимонад партии batch россыпью на «Основной».
func (e *pickEnv) stock(cell, batch string, qty int) {
	e.t.Helper()
	if _, err := e.pool.Exec(e.ctx, `INSERT INTO stock (cell_id,good_id,batch_id,qty,internal_warehouse_id)
		VALUES ($1,$2,$3,$4,$5)`, cell, e.lemon, batch, qty, e.main); err != nil {
		e.t.Fatalf("остаток: %v", err)
	}
}

// qty — остаток лимонада в ячейке по всем партиям.
func (e *pickEnv) qty(cell string) string {
	e.t.Helper()
	return e.scan(`SELECT coalesce(sum(qty), 0)::int::text FROM stock WHERE cell_id = $1 AND good_id = $2`, cell, e.lemon)
}

// shippingQty — сколько лежит в ячейке ОТГРУЗКА.
func (e *pickEnv) shippingQty() string {
	e.t.Helper()
	return e.scan(`SELECT coalesce(sum(s.qty), 0)::int::text FROM stock s JOIN cells c ON c.id = s.cell_id
		WHERE c.is_shipping`)
}

// registry загружает реестр строками {накладная, заказ, клиент, код, количество} от оператора.
func (e *pickEnv) registry(rows ...[5]string) RegistryPreview {
	e.t.Helper()
	res, err := e.load.Load(e.ctx, "SHB", "Реестр.xlsx", e.office, bytes.NewReader(registryFile(e.t, rows)))
	if err != nil {
		e.t.Fatalf("загрузка реестра: %v", err)
	}
	return *res
}

// order — id заказа сборки по номеру заказа 1С.
func (e *pickEnv) order(number string) string {
	e.t.Helper()
	return e.scan(`SELECT id::text FROM picking_orders WHERE order_number = $1`, number)
}

// start — кладовщик берёт заказ и заводит короб отгрузки; возвращает ярлык короба.
func (e *pickEnv) start(order, user string) string {
	e.t.Helper()
	if err := e.task.Take(e.ctx, order, user); err != nil {
		e.t.Fatalf("взять заказ: %v", err)
	}
	box := uuid.NewString()
	if _, err := e.task.AddBox(e.ctx, order, user, box); err != nil {
		e.t.Fatalf("короб отгрузки: %v", err)
	}
	return box
}

// pickBySuggestion собирает заказ по подбору, как ТСД: каждый источник подсказки - пик
// операцией очереди. Возвращает подбор - что сервер предложил.
func (e *pickEnv) pickBySuggestion(order, user, box string) PickingTask {
	e.t.Helper()
	task, err := e.task.Task(e.ctx, order)
	if err != nil {
		e.t.Fatalf("задание: %v", err)
	}
	for _, l := range task.Lines {
		if l.Suggestion == nil {
			continue
		}
		for _, take := range l.Suggestion.Takes {
			if _, err := e.pick(order, l.Line.ID, user, box, take.Source.CellID,
				take.Source.BatchDate.Format(time.DateOnly), int(take.Qty.IntPart())); err != nil {
				e.t.Fatalf("пик %s из %s: %v", take.Qty, take.Source.CellAddress, err)
			}
		}
	}
	return task
}

// pick — пик россыпью операцией очереди picking_pick.
func (e *pickEnv) pick(order, line, user, box, cell, batch string, qty int) (repository.Applied, error) {
	return e.ops.PickingPick(e.ctx, uuid.NewString(), repository.PickingPickInput{
		PickID: uuid.NewString(), OrderID: order, LineID: line, BoxID: box, SourceCellID: cell,
		InternalWarehouseID: e.main, ProductionDate: batch, Qty: decimal.NewFromInt(int64(qty)), PickedBy: user,
	})
}

// ship — «Завершить сборку», печать ярлыков и отгрузка сканом всех коробов.
func (e *pickEnv) ship(order, user string) model.PickingShipment {
	e.t.Helper()
	s, err := e.task.Complete(e.ctx, order, user)
	if err != nil {
		e.t.Fatalf("завершить сборку: %v", err)
	}
	ids := make([]string, 0, len(s.Boxes))
	for _, b := range s.Boxes {
		ids = append(ids, b.LoadUnitID)
	}
	if len(ids) > 0 {
		if _, err := e.task.PrintLabels(e.ctx, order, ids, false); err != nil {
			e.t.Fatalf("ярлыки: %v", err)
		}
	}
	s, err = e.task.Ship(e.ctx, order, user, ids)
	if err != nil || s.Status != model.PickingStatusShipped {
		e.t.Fatalf("отгрузить: %+v, %v", s, err)
	}
	return s
}

// portalOrder — заказ в окне деталей портала.
func (e *pickEnv) portalOrder(order string) model.PickingPortalDetail {
	e.t.Helper()
	d, err := e.portal.Order(e.ctx, order)
	if err != nil {
		e.t.Fatalf("заказ в портале: %v", err)
	}
	return d
}

// events — журнал заказа строкой «вид:кто», через запятую.
func (e *pickEnv) events(order string) string {
	e.t.Helper()
	return e.scan(`SELECT string_agg(e.kind || ':' || u.full_name, ',' ORDER BY e.seq)
		FROM picking_order_events e JOIN users u ON u.id = e.user_id WHERE e.order_id = $1`, order)
}

// TestPickingScenario_full — полная сборка: реестр → подбор FEFO (старая партия первой) → пик в
// короб → «Завершить сборку» (товар из ячеек в ОТГРУЗКУ) → отгрузка (товар ушёл со склада) →
// портал: отгружен, сходится с 1С, журнал. Повторная загрузка того же файла ничего не меняет.
func TestPickingScenario_full(t *testing.T) {
	e := newPickEnv(t)
	e.stock(e.cellA, e.newA, 10)
	e.stock(e.cellB, e.oldB, 4)
	file := [5]string{"21048", "15787", "ИП Махатадзе", "00000016147", "6"}
	if res := e.registry(file); res.Counts.New != 1 {
		t.Fatalf("загрузка: %+v", res.Counts)
	}
	order := e.order("15787")

	box := e.start(order, e.ann)
	task := e.pickBySuggestion(order, e.ann, box)
	sg := task.Lines[0].Suggestion
	if len(sg.Takes) != 2 || sg.Takes[0].Source.CellAddress != "B-1" || !sg.Short.IsZero() {
		t.Fatalf("подбор FEFO: сначала 4 из B-1 (01.09), затем 2 из A-1: %+v", sg)
	}
	// Пики не трогают остаток: товар «в сборке» числится в ячейке до завершения.
	if a, b := e.qty(e.cellA), e.qty(e.cellB); a != "10" || b != "4" {
		t.Fatalf("до завершения A-1 %s, B-1 %s", a, b)
	}

	s, err := e.task.Complete(e.ctx, order, e.ann)
	if err != nil || s.IsPartial || len(s.Boxes) != 1 {
		t.Fatalf("завершить: %+v, %v", s, err)
	}
	if a, b, sh := e.qty(e.cellA), e.qty(e.cellB), e.shippingQty(); a != "8" || b != "0" || sh != "6" {
		t.Fatalf("после завершения A-1 %s, B-1 %s, ОТГРУЗКА %s", a, b, sh)
	}
	if _, err := e.task.Ship(e.ctx, order, e.bob, []string{s.Boxes[0].LoadUnitID}); err != nil {
		t.Fatalf("отгрузить: %v", err)
	}
	if sh := e.shippingQty(); sh != "0" {
		t.Fatalf("после отгрузки в ОТГРУЗКЕ %s", sh)
	}

	d := e.portalOrder(order)
	if d.Order.Status != model.PickingStatusShipped || d.Order.OutOfSync || d.Order.PickedByName != "Анна" ||
		!d.Order.FactQty.Equal(decimal.NewFromInt(6)) {
		t.Fatalf("портал: %+v", d.Order)
	}
	if got := e.events(order); got != "taken:Анна,completed:Анна,shipped:Борис" {
		t.Fatalf("журнал: %s", got)
	}
	if res := e.registry(file); res.Counts.Unchanged != 1 {
		t.Fatalf("повтор файла: %+v", res.Counts)
	}
	if n := e.scan(`SELECT count(*)::text FROM picking_order_changes`); n != "0" {
		t.Fatalf("правок после повтора файла: %s", n)
	}
}

// TestPickingScenario_shortage — частичная сборка и сверка с 1С: менеджер уменьшает заказ до
// сборки («изменение заказа в 1С»); на складе меньше плана - подбор показывает нехватку,
// завершение без «не хватает» - отказ, с отметкой - пересчёт позиции и «собран частично».
// Отгруженный заказ расходится с 1С, пока реестр не приведёт план к факту.
func TestPickingScenario_shortage(t *testing.T) {
	e := newPickEnv(t)
	e.stock(e.cellA, e.newA, 3)
	e.registry([5]string{"21048", "15787", "ИП Махатадзе", "00000016147", "6"})
	e.registry([5]string{"21048", "15787", "ИП Махатадзе", "00000016147", "5"})
	order := e.order("15787")

	box := e.start(order, e.ann)
	task := e.pickBySuggestion(order, e.ann, box)
	line := task.Lines[0]
	if !line.Suggestion.Short.Equal(decimal.NewFromInt(2)) {
		t.Fatalf("нехватка по подбору: %s", line.Suggestion.Short)
	}
	var lerr *model.PickingLinesError
	if _, err := e.task.Complete(e.ctx, order, e.ann); !errors.As(err, &lerr) {
		t.Fatalf("завершение без «не хватает»: %v", err)
	}
	sh, err := e.task.MarkShortage(e.ctx, order, line.Line.ID, e.ann, true)
	if err != nil || !sh.Created || sh.StocktakeNumber == nil {
		t.Fatalf("«не хватает» - пересчёт позиции: %+v, %v", sh, err)
	}
	if s := e.ship(order, e.ann); !s.IsPartial {
		t.Fatalf("собран частично: %+v", s)
	}

	d := e.portalOrder(order)
	if !d.Order.OutOfSync || !d.Order.IsPartial {
		t.Fatalf("отгружено 3 из 5 - расходится с 1С: %+v", d.Order)
	}
	// Оператор поправил реализацию в 1С на отгруженное и загрузил реестр.
	e.registry([5]string{"21048", "15787", "ИП Махатадзе", "00000016147", "3"})
	d = e.portalOrder(order)
	if d.Order.OutOfSync || !d.Order.ChangedAfterShipment || d.Order.PlanQty != 3 {
		t.Fatalf("после правки 1С - сходится: %+v", d.Order)
	}
	reasons := make([]string, 0, len(d.Changes))
	for _, c := range d.Changes {
		reasons = append(reasons, c.Reason)
	}
	if want := []string{model.PickingChangeReasonOrder, model.PickingChangeReasonFit}; !equalStrings(reasons, want) {
		t.Fatalf("причины правок: %v, ждали %v", reasons, want)
	}
	if n := e.scan(`SELECT count(*)::text FROM warehouse_tasks WHERE picking_order_id = $1`, order); n != "0" {
		t.Fatalf("у отгруженного заказа возврата на места нет: %s", n)
	}
}

// TestPickingScenario_competition — две сборки на один остаток: резерва нет, остаток делит пик.
// Анна взяла все 5 шт. в свой заказ; Борису подбор показывает нехватку, а пик из той же ячейки
// - отказ. Анна завершила и отгрузила; Борис отмечает «не хватает» по позиции и закрывает свой
// заказ пустой отгрузкой.
func TestPickingScenario_competition(t *testing.T) {
	e := newPickEnv(t)
	e.stock(e.cellA, e.newA, 5)
	e.registry(
		[5]string{"21048", "15787", "ИП Махатадзе", "00000016147", "5"},
		[5]string{"21049", "15788", "ИП Суслова", "00000016147", "5"},
	)
	first, second := e.order("15787"), e.order("15788")

	boxA := e.start(first, e.ann)
	e.pickBySuggestion(first, e.ann, boxA)

	boxB := e.start(second, e.bob)
	task, err := e.task.Task(e.ctx, second)
	if err != nil {
		t.Fatalf("задание Бориса: %v", err)
	}
	line := task.Lines[0]
	if !line.Suggestion.Short.Equal(decimal.NewFromInt(5)) || len(line.Suggestion.Takes) != 0 {
		t.Fatalf("подбор Бориса - всё «в сборке» у Анны: %+v", line.Suggestion)
	}
	if _, err := e.pick(second, line.Line.ID, e.bob, boxB, e.cellA, "2026-10-01", 1); !errors.Is(err, model.ErrPickingStockShort) {
		t.Fatalf("пик из занятого остатка: %v", err)
	}

	e.ship(first, e.ann)
	if a := e.qty(e.cellA); a != "0" {
		t.Fatalf("после отгрузки Анны в A-1 %s", a)
	}
	if _, err := e.task.MarkShortage(e.ctx, second, line.Line.ID, e.bob, true); err != nil {
		t.Fatalf("«не хватает» у Бориса: %v", err)
	}
	if s := e.ship(second, e.bob); !s.IsPartial || len(s.Boxes) != 0 {
		t.Fatalf("заказ Бориса закрыт пустым: %+v", s)
	}
	if d := e.portalOrder(second); !d.Order.OutOfSync || !d.Order.FactQty.IsZero() {
		t.Fatalf("пустая отгрузка расходится с 1С: %+v", d.Order)
	}
}
