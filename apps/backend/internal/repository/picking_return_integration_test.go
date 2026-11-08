package repository_test

import (
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

// returnFixture — склад, ячейки, кладовщик, лимонад и маркируемая вода с остатком в A-1 (P9-07-1).
type returnFixture struct {
	t                        *testing.T
	pool                     *pgxpool.Pool
	wh, cellA, cellC, ship   string
	user, good, marked, main string
	mark1, mark2             string
	pk                       *repository.PickingRepository
	ops                      *repository.OperationsRepository
	registry                 time.Time
}

func newReturnFixture(t *testing.T) *returnFixture {
	pool := testutil.StartPostgres(t)
	ctx := context.Background()
	f := &returnFixture{t: t, pool: pool, mark1: "0104600000000017215BACK1", mark2: "0104600000000017215BACK2",
		pk: repository.NewPickingRepository(pool), ops: repository.NewOperationsRepository(pool),
		registry: time.Date(2026, 11, 9, 0, 0, 0, 0, time.UTC)}
	f.wh = f.scan(`INSERT INTO warehouses (code,name) VALUES ('SHB','Шабулина') RETURNING id::text`)
	f.cellA = f.scan(`INSERT INTO cells (warehouse_id,address) VALUES ($1,'A-1') RETURNING id::text`, f.wh)
	f.cellC = f.scan(`INSERT INTO cells (warehouse_id,address) VALUES ($1,'C-1') RETURNING id::text`, f.wh)
	ship, err := repository.NewCellRepository(pool).EnsureShipping(ctx, pool, f.wh)
	if err != nil {
		t.Fatalf("EnsureShipping: %v", err)
	}
	f.ship = ship
	f.user = f.scan(`INSERT INTO users (login,password_hash,full_name) VALUES ('90000052','x','Кладовщик') RETURNING id::text`)
	f.good = f.scan(`INSERT INTO goods (code,name,uom) VALUES ('16147','Лимонад','шт') RETURNING id::text`)
	f.marked = f.scan(`INSERT INTO goods (code,name,uom,cz_marked) VALUES ('16149','Вода','шт',true) RETURNING id::text`)
	batch := f.scan(`INSERT INTO batches (good_id,production_date) VALUES ($1,'2026-10-01') RETURNING id::text`, f.good)
	mbatch := f.scan(`INSERT INTO batches (good_id,production_date) VALUES ($1,'2026-10-01') RETURNING id::text`, f.marked)
	f.main = f.scan(`SELECT id::text FROM internal_warehouses WHERE is_default`)
	f.exec(`INSERT INTO stock (cell_id,good_id,batch_id,qty,internal_warehouse_id) VALUES ($1,$2,$3,20,$4)`,
		f.cellA, f.good, batch, f.main)
	f.exec(`INSERT INTO stock (cell_id,good_id,batch_id,qty,internal_warehouse_id) VALUES ($1,$2,$3,2,$4)`,
		f.cellA, f.marked, mbatch, f.main)
	for _, cis := range []string{f.mark1, f.mark2} {
		f.exec(`INSERT INTO cz_marks (cis,good_id,batch_id,cell_id,internal_warehouse_id) VALUES ($1,$2,$3,$4,$5)`,
			cis, f.marked, mbatch, f.cellA, f.main)
	}
	return f
}

func (f *returnFixture) scan(sql string, args ...any) string {
	f.t.Helper()
	var v string
	mustScan(f.t, f.pool, sql, &v, args...)
	return v
}

func (f *returnFixture) exec(sql string, args ...any) {
	f.t.Helper()
	if _, err := f.pool.Exec(context.Background(), sql, args...); err != nil {
		f.t.Fatalf("%s: %v", sql, err)
	}
}

// order заводит заказ «лимонад 8 + вода 2» с номером 1С number и возвращает заказ и строки.
func (f *returnFixture) order(number string) (order, line, mline string) {
	load := f.scan(`INSERT INTO picking_loads (warehouse_id,registry_date,file_name,uploaded_by)
		VALUES ($1,$2,'Реестр.xlsx',$3) RETURNING id::text`, f.wh, f.registry, f.user)
	order = f.scan(`INSERT INTO picking_orders (warehouse_id,registry_date,invoice_number,order_number,created_load_id,updated_load_id)
		VALUES ($1,$2,'20961',$4,$3,$3) RETURNING id::text`, f.wh, f.registry, load, number)
	line = f.scan(`INSERT INTO picking_order_lines (order_id,line_no,good_code,good_name,good_id,plan_qty)
		VALUES ($1,1,'00000016147','Лимонад',$2,8) RETURNING id::text`, order, f.good)
	mline = f.scan(`INSERT INTO picking_order_lines (order_id,line_no,good_code,good_name,good_id,plan_qty)
		VALUES ($1,2,'00000016149','Вода',$2,2) RETURNING id::text`, order, f.marked)
	return order, line, mline
}

func (f *returnFixture) pick(order string, in repository.PickingPickInput) string {
	f.t.Helper()
	in.PickID, in.OrderID, in.PickedBy, in.ProductionDate = uuid.NewString(), order, f.user, "2026-10-01"
	if _, err := f.ops.PickingPick(context.Background(), uuid.NewString(), in); err != nil {
		f.t.Fatalf("пик: %v", err)
	}
	return in.PickID
}

// reload — повторная загрузка реестра: план одного заказа, как его построил бы сервис.
func (f *returnFixture) reload(plan model.PickingOrderPlan) {
	f.t.Helper()
	_, _, err := f.pk.Load(context.Background(), model.PickingLoadInput{
		WarehouseID: f.wh, RegistryDate: f.registry, FileName: "Реестр-2.xlsx", UploadedBy: f.user,
	}, func([]model.PickingExistingOrder) ([]model.PickingOrderPlan, error) {
		return []model.PickingOrderPlan{plan}, nil
	})
	if err != nil {
		f.t.Fatalf("загрузка реестра: %v", err)
	}
}

func (f *returnFixture) qty(cell, good string) string {
	return f.scan(`SELECT coalesce(sum(qty), 0)::int::text FROM stock WHERE cell_id = $1 AND good_id = $2`, cell, good)
}

func (f *returnFixture) returnPick(pickID, cell string, qty int64, marks ...string) error {
	_, err := f.ops.PickingReturn(context.Background(), uuid.NewString(), repository.PickingReturnInput{
		ReturnID: uuid.NewString(), PickID: pickID, CellID: cell, Qty: decimal.NewFromInt(qty), Marks: marks,
		UserID: f.user,
	})
	return err
}

// TestPickingReturn — возврат на места из коробов собранного заказа после правки реестра (P9-07-1).
//
// Собран заказ: лимонад 8 (пики 5 и 3) в коробе 1, вода 2 марками в коробе 2. Реестр убавил
// лимонад до 5 и убрал воду: заводится задание «вернуть на места» на 5 шт., отгрузка закрыта.
// Возврат больше остатка, в ячейку отгрузки и чужими марками — отказ. Лимонад 3 шт. и воду
// марками — в C-1: остаток переехал из `ОТГРУЗКИ`, пик лимонада уменьшился, вода «возвращена»,
// пустой короб воды убран и снят с места, ярлыки сброшены. Задание выполнено, отгрузка прошла.
func TestPickingReturn(t *testing.T) {
	f := newReturnFixture(t)
	ctx := context.Background()
	order, line, mline := f.order("15512")
	if err := f.pk.TakeOrder(ctx, order, f.user, 0); err != nil {
		t.Fatalf("взять заказ: %v", err)
	}
	box1, box2 := uuid.NewString(), uuid.NewString()
	for _, b := range []string{box1, box2} {
		if _, err := f.pk.AddBox(ctx, order, f.user, b); err != nil {
			t.Fatalf("короб отгрузки: %v", err)
		}
	}
	big := f.pick(order, repository.PickingPickInput{LineID: line, BoxID: box1, SourceCellID: f.cellA, Qty: decimal.NewFromInt(5)})
	f.pick(order, repository.PickingPickInput{LineID: line, BoxID: box1, SourceCellID: f.cellA, Qty: decimal.NewFromInt(3)})
	water := f.pick(order, repository.PickingPickInput{LineID: mline, BoxID: box2, SourceCellID: f.cellA,
		Qty: decimal.NewFromInt(2), Marks: []string{f.mark1, f.mark2}})
	if _, err := f.pk.CompleteOrder(ctx, order, f.user); err != nil {
		t.Fatalf("завершить: %v", err)
	}
	if _, err := f.pk.PrintLabels(ctx, order, []string{box1, box2}, false); err != nil {
		t.Fatalf("ярлыки: %v", err)
	}

	gid := f.good
	f.reload(model.PickingOrderPlan{
		Kind: model.PickingOrderChanged, ExistingID: order, Status: model.PickingStatusPicked,
		Header:         &model.PickingOrderHeader{InvoiceNumber: "20961", OrderNumber: "15512"},
		Lines:          []model.PickingPlanLine{{ExistingID: line, GoodCode: "00000016147", GoodName: "Лимонад", GoodID: &gid, Qty: 5}},
		RemovedLineIDs: []string{mline},
	})
	if v := f.scan(`SELECT count(*)::text FROM warehouse_tasks WHERE kind = 'picking_return' AND picking_order_id = $1 AND status = 'new'`, order); v != "1" {
		t.Fatalf("задание «вернуть на места»: %s", v)
	}
	s, err := f.pk.Shipment(ctx, order)
	if err != nil || !s.ReturnLeft.Equal(decimal.NewFromInt(5)) {
		t.Fatalf("вернуть по заказу: %+v, %v", s.ReturnLeft, err)
	}
	if _, err := f.pk.ShipOrder(ctx, order, f.user, []string{box1, box2}); !errors.Is(err, model.ErrPickingReturnPending) {
		t.Fatalf("отгрузка до возврата: %v", err)
	}
	v, err := f.pk.ReturnView(ctx, order)
	if err != nil || len(v.Lines) != 2 || len(v.Picks) != 3 || v.TaskID == nil {
		t.Fatalf("что вернуть: %+v, %v", v, err)
	}

	if err := f.returnPick(big, f.cellC, 4); !errors.Is(err, model.ErrPickingReturnOverLeft) {
		t.Fatalf("больше остатка: %v", err)
	}
	if err := f.returnPick(big, f.ship, 3); !errors.Is(err, model.ErrPickingReturnCell) {
		t.Fatalf("в ячейку отгрузки: %v", err)
	}
	if err := f.returnPick(water, f.cellC, 2, f.mark1, "0104600000000017215OTHER"); !errors.Is(err, model.ErrPickingReturnMarks) {
		t.Fatalf("чужая марка: %v", err)
	}
	if err := f.returnPick(water, f.cellC, 1); !errors.Is(err, model.ErrPickingReturnMarks) {
		t.Fatalf("маркируемый без марок: %v", err)
	}

	if err := f.returnPick(big, f.cellC, 3); err != nil {
		t.Fatalf("вернуть лимонад: %v", err)
	}
	if c, sh := f.qty(f.cellC, f.good), f.qty(f.ship, f.good); c != "3" || sh != "5" {
		t.Fatalf("остаток лимонада: C-1 %s, ОТГРУЗКА %s", c, sh)
	}
	if got := f.scan(`SELECT state || ':' || qty::int FROM picking_picks WHERE id = $1`, big); got != "moved:2" {
		t.Fatalf("пик лимонада: %s", got)
	}
	if got := f.scan(`SELECT qty::int::text FROM lu_content WHERE load_unit_id = $1`, box1); got != "5" {
		t.Fatalf("короб 1: %s", got)
	}
	if err := f.returnPick(water, f.cellC, 2, f.mark2, f.mark1); err != nil {
		t.Fatalf("вернуть воду: %v", err)
	}
	if got := f.scan(`SELECT count(*)::text FROM cz_marks WHERE cell_id = $1 AND load_unit_id IS NULL AND internal_warehouse_id = $2`,
		f.cellC, f.main); got != "2" {
		t.Fatalf("марки в C-1: %s", got)
	}
	if got := f.scan(`SELECT state FROM picking_picks WHERE id = $1`, water); got != "returned" {
		t.Fatalf("пик воды: %s", got)
	}
	if got := f.scan(`SELECT (b.dropped_at IS NOT NULL)::text || ':' || l.status || ':' || (l.cell_id IS NULL)::text
		FROM picking_boxes b JOIN load_units l ON l.id = b.load_unit_id WHERE b.load_unit_id = $1`, box2); got != "true:closed:true" {
		t.Fatalf("пустой короб воды: %s", got)
	}
	s, err = f.pk.Shipment(ctx, order)
	if err != nil || !s.ReturnLeft.IsZero() || len(s.Boxes) != 1 || s.Boxes[0].LabelsPrinted != 0 ||
		!s.Qty.Equal(decimal.NewFromInt(5)) {
		t.Fatalf("заказ после возврата: %+v, %v", s, err)
	}
	if got := f.scan(`SELECT status || ':' || (completed_by = $2)::text FROM warehouse_tasks WHERE picking_order_id = $1`,
		order, f.user); got != "done:true" {
		t.Fatalf("задание после возврата: %s", got)
	}
	if err := f.returnPick(big, f.cellC, 1); !errors.Is(err, model.ErrPickingReturnOverLeft) {
		t.Fatalf("возврат сверх задания: %v", err)
	}
	if _, err := f.pk.ShipOrder(ctx, order, f.user, []string{box1}); err != nil {
		t.Fatalf("отгрузить: %v", err)
	}
	if got := f.scan(`SELECT string_agg(kind || coalesce(':' || qty::int, ''), ',' ORDER BY seq)
		FROM picking_order_events WHERE order_id = $1`, order); got != "taken,completed:10,returned:3,returned:2,shipped:5" {
		t.Fatalf("журнал: %s", got)
	}
}

// TestPickingReturnTaskLifecycle — задание следует за реестром (P9-07-1).
//
// Собранный заказ убавлен — задание заведено; реестр вернул прежний план — задание снято: по нему
// ничего не делали. Удалённый заказ «в работе» с открытым пиком — задание на взятое; его взяли и
// вернули пик в источник — задание выполнено, «в сборке» нет, остаток в ячейке не двигался.
func TestPickingReturnTaskLifecycle(t *testing.T) {
	f := newReturnFixture(t)
	ctx := context.Background()
	order, line, mline := f.order("15512")
	if err := f.pk.TakeOrder(ctx, order, f.user, 0); err != nil {
		t.Fatalf("взять заказ: %v", err)
	}
	box := uuid.NewString()
	if _, err := f.pk.AddBox(ctx, order, f.user, box); err != nil {
		t.Fatalf("короб отгрузки: %v", err)
	}
	f.pick(order, repository.PickingPickInput{LineID: line, BoxID: box, SourceCellID: f.cellA, Qty: decimal.NewFromInt(8)})
	if _, err := f.pk.MarkShortage(ctx, order, mline, f.user, true); err != nil {
		t.Fatalf("не хватает: %v", err)
	}
	if _, err := f.pk.CompleteOrder(ctx, order, f.user); err != nil {
		t.Fatalf("завершить: %v", err)
	}
	gid := f.good
	plan := func(qty int) model.PickingOrderPlan {
		return model.PickingOrderPlan{
			Kind: model.PickingOrderChanged, ExistingID: order, Status: model.PickingStatusPicked,
			Header: &model.PickingOrderHeader{InvoiceNumber: "20961", OrderNumber: "15512"},
			Lines:  []model.PickingPlanLine{{ExistingID: line, GoodCode: "00000016147", GoodName: "Лимонад", GoodID: &gid, Qty: qty}},
		}
	}
	tasks := func(status string) string {
		return f.scan(`SELECT count(*)::text FROM warehouse_tasks WHERE picking_order_id = $1 AND status = $2`, order, status)
	}
	f.reload(plan(6))
	if tasks("new") != "1" {
		t.Fatalf("задание не заведено")
	}
	f.reload(plan(8))
	if tasks("new") != "0" || tasks("done") != "0" {
		t.Fatalf("задание не снято")
	}

	// Удалённый заказ «в работе»: взятое ещё у источника.
	order2, line2, _ := f.order("15513")
	if err := f.pk.TakeOrder(ctx, order2, f.user, 0); err != nil {
		t.Fatalf("взять заказ 2: %v", err)
	}
	box2 := uuid.NewString()
	if _, err := f.pk.AddBox(ctx, order2, f.user, box2); err != nil {
		t.Fatalf("короб отгрузки 2: %v", err)
	}
	open := f.pick(order2, repository.PickingPickInput{LineID: line2, BoxID: box2, SourceCellID: f.cellA, Qty: decimal.NewFromInt(4)})
	f.reload(model.PickingOrderPlan{Kind: model.PickingOrderDeleted, ExistingID: order2, Status: model.PickingStatusInProgress,
		Changes: []model.PickingChange{{Kind: model.PickingChangeOrderDeleted}}})
	task := f.scan(`SELECT id::text FROM warehouse_tasks WHERE picking_order_id = $1 AND status = 'new'`, order2)
	v, err := f.pk.ReturnView(ctx, order2)
	if err != nil || len(v.Picks) != 1 || v.Picks[0].Moved || !v.Deleted {
		t.Fatalf("что вернуть у удалённого: %+v, %v", v, err)
	}
	if err := f.returnPick(open, f.cellC, 4); !errors.Is(err, model.ErrPickingReturnNotMoved) {
		t.Fatalf("открытый пик возвратом: %v", err)
	}
	if err := repository.NewTaskRepository(f.pool).Take(ctx, task, f.user, time.Hour); err != nil {
		t.Fatalf("взять задание: %v", err)
	}
	if _, err := f.ops.PickingUnpick(ctx, uuid.NewString(), open); err != nil {
		t.Fatalf("вернуть в источник: %v", err)
	}
	if got := f.scan(`SELECT status FROM warehouse_tasks WHERE id = $1`, task); got != "done" {
		t.Fatalf("задание удалённого: %s", got)
	}
	if a := f.qty(f.cellA, f.good); a != "12" {
		t.Fatalf("остаток A-1: %s", a)
	}
}
