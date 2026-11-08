package repository_test

import (
	"context"
	"errors"
	"testing"

	"github.com/google/uuid"
	"github.com/shopspring/decimal"

	"craftwms/internal/model"
	"craftwms/internal/repository"
	"craftwms/internal/testutil"
)

// TestPickingPick — пик и «в сборке» по живой базе (P9-05).
//
// В A-1 20 шт. россыпью, в коробе хранения в B-1 — 6 шт., в A-1 же две марки маркируемого
// товара. Пик 5 шт. россыпью: повтор операции второй раз не пикает, «в сборке» видно в
// содержимом, перемещение берёт не больше 15, а снимок пересчёта ячейки ждёт 15. Пик сверх
// плана и сверх доступного — отказ. Короб с открытым пиком переезжает вместе со своим «в сборке»,
// пометить его проблемой целиком нельзя. Маркируемый — только марками, марка в сборке не
// перемещается и не берётся вторым пиком. Ячейка отгрузки — не источник сборки и не место
// перемещения. Возврат пика снимает «в сборке»; удалённый заказ не пикается.
func TestPickingPick(t *testing.T) {
	pool := testutil.StartPostgres(t)
	ctx := context.Background()
	scan := func(sql string, args ...any) string {
		t.Helper()
		var v string
		mustScan(t, pool, sql, &v, args...)
		return v
	}
	exec := func(sql string, args ...any) {
		t.Helper()
		if _, err := pool.Exec(ctx, sql, args...); err != nil {
			t.Fatalf("%s: %v", sql, err)
		}
	}

	wh := scan(`INSERT INTO warehouses (code,name) VALUES ('SHB','Шабулина') RETURNING id::text`)
	cell := func(address string) string {
		return scan(`INSERT INTO cells (warehouse_id,address) VALUES ($1,$2) RETURNING id::text`, wh, address)
	}
	cellA, cellB, cellC := cell("A-1"), cell("B-1"), cell("C-1")
	shipping, err := repository.NewCellRepository(pool).EnsureShipping(ctx, pool, wh)
	if err != nil {
		t.Fatalf("EnsureShipping: %v", err)
	}
	user := scan(`INSERT INTO users (login,password_hash,full_name) VALUES ('90000046','x','Кладовщик') RETURNING id::text`)
	good := scan(`INSERT INTO goods (code,name,uom) VALUES ('16147','Лимонад','шт') RETURNING id::text`)
	marked := scan(`INSERT INTO goods (code,name,uom,cz_marked) VALUES ('16149','Вода','шт',true) RETURNING id::text`)
	batch := scan(`INSERT INTO batches (good_id,production_date) VALUES ($1,'2026-10-01') RETURNING id::text`, good)
	mbatch := scan(`INSERT INTO batches (good_id,production_date) VALUES ($1,'2026-10-01') RETURNING id::text`, marked)
	main := scan(`SELECT id::text FROM internal_warehouses WHERE is_default`)
	defect := scan(`SELECT id::text FROM internal_warehouses WHERE code = 'DEFECT'`)
	stock := func(cell, good, batch, qty string) {
		exec(`INSERT INTO stock (cell_id,good_id,batch_id,qty,internal_warehouse_id) VALUES ($1,$2,$3,$4,$5)`,
			cell, good, batch, qty, main)
	}
	stock(cellA, good, batch, "20")
	stock(cellB, good, batch, "6")
	stock(cellA, marked, mbatch, "2")
	storage := scan(`INSERT INTO load_units (id,kind,cell_id,status) VALUES (gen_random_uuid(),'box',$1,'placed') RETURNING id::text`, cellB)
	exec(`INSERT INTO lu_content (load_unit_id,good_id,batch_id,qty) VALUES ($1,$2,$3,6)`, storage, good, batch)
	const mark1, mark2 = "0104600000000017215PICK1", "0104600000000017215PICK2"
	for _, cis := range []string{mark1, mark2} {
		exec(`INSERT INTO cz_marks (cis,good_id,batch_id,cell_id,internal_warehouse_id) VALUES ($1,$2,$3,$4,$5)`,
			cis, marked, mbatch, cellA, main)
	}

	load := scan(`INSERT INTO picking_loads (warehouse_id,registry_date,file_name,uploaded_by)
		VALUES ($1,'2026-11-09','Реестр.xlsx',$2) RETURNING id::text`, wh, user)
	order := scan(`INSERT INTO picking_orders (warehouse_id,registry_date,invoice_number,order_number,created_load_id,updated_load_id)
		VALUES ($1,'2026-11-09','20961','15512',$2,$2) RETURNING id::text`, wh, load)
	line := scan(`INSERT INTO picking_order_lines (order_id,line_no,good_code,good_id,plan_qty)
		VALUES ($1,1,'00000016147',$2,8) RETURNING id::text`, order, good)
	mline := scan(`INSERT INTO picking_order_lines (order_id,line_no,good_code,good_id,plan_qty)
		VALUES ($1,2,'00000016149',$2,2) RETURNING id::text`, order, marked)

	pk := repository.NewPickingRepository(pool)
	if err := pk.TakeOrder(ctx, order, user, 0); err != nil {
		t.Fatalf("взять заказ: %v", err)
	}
	box := uuid.NewString()
	if _, err := pk.AddBox(ctx, order, user, box); err != nil {
		t.Fatalf("короб отгрузки: %v", err)
	}

	ops := repository.NewOperationsRepository(pool)
	pick := func(opID string, in repository.PickingPickInput) (repository.Applied, error) {
		in.OrderID, in.BoxID, in.PickedBy, in.ProductionDate = order, box, user, "2026-10-01"
		if in.PickID == "" {
			in.PickID = uuid.NewString()
		}
		if in.LineID == "" {
			in.LineID = line
		}
		return ops.PickingPick(ctx, opID, in)
	}
	five := decimal.NewFromInt(5)

	// Пик 5 шт. россыпью A-1; повтор той же операции — дубль, второй пик не появляется.
	firstPick, firstOp := uuid.NewString(), uuid.NewString()
	if _, err := pick(firstOp, repository.PickingPickInput{PickID: firstPick, SourceCellID: cellA, Qty: five}); err != nil {
		t.Fatalf("пик: %v", err)
	}
	if a, err := pick(firstOp, repository.PickingPickInput{PickID: firstPick, SourceCellID: cellA, Qty: five}); err != nil || !a.Duplicate {
		t.Fatalf("повтор пика: %+v, %v", a, err)
	}
	if n := scan(`SELECT count(*)::text FROM picking_picks WHERE order_id = $1`, order); n != "1" {
		t.Fatalf("пиков %s, ждали 1", n)
	}

	// «В сборке» видно в содержимом ячейки; остаток ячейки не тронут.
	contents, err := repository.NewContentsRepository(pool).CellContents(ctx, cellA)
	if err != nil {
		t.Fatalf("содержимое A-1: %v", err)
	}
	for _, l := range contents.Loose {
		if l.GoodID == good && (!l.Qty.Equal(decimal.NewFromInt(20)) || !l.InPicking.Equal(five)) {
			t.Fatalf("россыпь A-1: %s, в сборке %s", l.Qty, l.InPicking)
		}
	}

	// Перемещение из A-1 — не больше доступного: 16 нельзя, 15 можно (и вернём обратно).
	move := func(lines ...repository.MovementLineInput) error {
		_, err := ops.MovementSubmit(ctx, uuid.NewString(), repository.MovementSubmitInput{
			MovementID: uuid.NewString(), Kind: model.MovementMove, WarehouseID: wh, CreatedBy: user, Lines: lines,
		})
		return err
	}
	goods := func(from, to string, qty int64) repository.MovementLineInput {
		return repository.MovementLineInput{GoodID: good, ProductionDate: "2026-10-01", Qty: decimal.NewFromInt(qty),
			FromCellID: from, ToCellID: to}
	}
	if err := move(goods(cellA, cellC, 16)); !errors.Is(err, repository.ErrGoodsShort) {
		t.Fatalf("перемещение сверх доступного: %v", err)
	}
	if err := move(goods(cellA, cellC, 15)); err != nil {
		t.Fatalf("перемещение доступного: %v", err)
	}
	if err := move(goods(cellC, cellA, 15)); err != nil {
		t.Fatalf("перемещение обратно: %v", err)
	}

	// Пик сверх плана — отказ: взято 5 из 8, ещё 4 нельзя; сверх доступного короба — тоже.
	if _, err := pick(uuid.NewString(), repository.PickingPickInput{SourceLoadUnitID: storage, Qty: decimal.NewFromInt(4)}); !errors.Is(err, model.ErrPickingOverPlan) {
		t.Fatalf("сверх плана: %v", err)
	}
	if _, err := pick(uuid.NewString(), repository.PickingPickInput{SourceLoadUnitID: storage, Qty: decimal.NewFromInt(3)}); err != nil {
		t.Fatalf("пик из короба: %v", err)
	}
	// Из короба 6 шт., 3 в сборке: вынуть 4 перемещением нельзя.
	fromBox := repository.MovementLineInput{GoodID: good, ProductionDate: "2026-10-01", Qty: decimal.NewFromInt(4),
		FromLoadUnitID: storage, ToCellID: cellC}
	if err := move(fromBox); !errors.Is(err, repository.ErrGoodsShort) {
		t.Fatalf("вынуть из короба сверх доступного: %v", err)
	}

	// Короб с открытым пиком переезжает со своим «в сборке»; пометить его целиком нельзя.
	if err := move(repository.MovementLineInput{LoadUnitID: storage, ToCellID: cellC}); err != nil {
		t.Fatalf("перенос короба: %v", err)
	}
	if src := scan(`SELECT source_cell_id::text FROM picking_picks WHERE source_load_unit_id = $1`, storage); src != cellC {
		t.Fatalf("«в сборке» не поехало с коробом: %s", src)
	}
	_, err = ops.ProblemSubmit(ctx, uuid.NewString(), repository.ProblemSubmitInput{
		ProblemID: uuid.NewString(), WarehouseID: wh, CreatedBy: user, LoadUnitID: storage,
		ToInternalWarehouseID: defect, Reason: "other", Comment: "проверка",
	})
	if !errors.Is(err, model.ErrPickingLoadUnitBusy) {
		t.Fatalf("пометка короба в сборке: %v", err)
	}

	// Маркируемый — только марками; марка в сборке не перемещается и вторым пиком не берётся.
	one := decimal.NewFromInt(1)
	if _, err := pick(uuid.NewString(), repository.PickingPickInput{LineID: mline, SourceCellID: cellA, Qty: one}); !errors.Is(err, model.ErrCZMarksRequired) {
		t.Fatalf("маркируемый без марок: %v", err)
	}
	if _, err := pick(uuid.NewString(), repository.PickingPickInput{LineID: mline, SourceCellID: cellA, Qty: one, Marks: []string{mark1}}); err != nil {
		t.Fatalf("пик марки: %v", err)
	}
	if _, err := pick(uuid.NewString(), repository.PickingPickInput{LineID: mline, SourceCellID: cellA, Qty: one, Marks: []string{mark1}}); !errors.Is(err, model.ErrPickingMarkInPicking) {
		t.Fatalf("марка вторым пиком: %v", err)
	}
	markMove := repository.MovementLineInput{GoodID: marked, ProductionDate: "2026-10-01", Qty: one,
		FromCellID: cellA, ToCellID: cellC, Marks: []string{mark1}}
	if err := move(markMove); !errors.Is(err, model.ErrPickingMarkInPicking) {
		t.Fatalf("перемещение марки в сборке: %v", err)
	}

	// Открытые пики в заказе (P9-06): россыпь A-1, короб хранения уже в C-1, марка.
	task, err := pk.TaskOrder(ctx, order)
	if err != nil {
		t.Fatalf("заказ с пиками: %v", err)
	}
	if len(task.Picks) != 3 {
		t.Fatalf("открытых пиков %d, ждали 3", len(task.Picks))
	}
	if p := task.Picks[0]; p.ID != firstPick || p.CellAddress != "A-1" || p.LoadUnitID != "" ||
		!p.Qty.Equal(five) || p.BoxID != box || len(p.Marks) != 0 {
		t.Fatalf("пик россыпи: %+v", p)
	}
	if p := task.Picks[1]; p.LoadUnitID != storage || p.CellAddress != "C-1" {
		t.Fatalf("пик из короба: %+v", p)
	}
	if p := task.Picks[2]; p.LineID != mline || len(p.Marks) != 1 || p.Marks[0] != mark1 {
		t.Fatalf("пик марки: %+v", p)
	}

	// Возврат пика снимает «в сборке»: теперь из A-1 доступно 20.
	if _, err := ops.PickingUnpick(ctx, uuid.NewString(), firstPick); err != nil {
		t.Fatalf("вернуть пик: %v", err)
	}
	if st := scan(`SELECT state FROM picking_picks WHERE id = $1`, firstPick); st != "returned" {
		t.Fatalf("состояние пика %s", st)
	}
	if err := move(goods(cellA, cellC, 20)); err != nil {
		t.Fatalf("после возврата пика доступно всё: %v", err)
	}

	// Ячейка отгрузки — не источник сборки и не место перемещения.
	stock(shipping, good, batch, "1")
	if _, err := pick(uuid.NewString(), repository.PickingPickInput{SourceCellID: shipping, Qty: one}); !errors.Is(err, model.ErrPickingSourceDenied) {
		t.Fatalf("пик из ОТГРУЗКИ: %v", err)
	}
	if err := move(goods(cellA, shipping, 1)); !errors.Is(err, repository.ErrShippingCell) {
		t.Fatalf("перемещение в ОТГРУЗКУ: %v", err)
	}

	// Удалённый в 1С заказ не пикается.
	exec(`UPDATE picking_orders SET deleted_at = now() WHERE id = $1`, order)
	if _, err := pick(uuid.NewString(), repository.PickingPickInput{SourceCellID: cellC, Qty: one}); !errors.Is(err, model.ErrPickingOrderDeleted) {
		t.Fatalf("пик удалённого: %v", err)
	}
}
