package repository_test

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/shopspring/decimal"

	"craftwms/internal/model"
	"craftwms/internal/repository"
	"craftwms/internal/testutil"
)

// TestPickingComplete — «Завершить сборку», ярлыки и отгрузка по живой базе (P9-07).
//
// Заказ: 8 шт. лимонада (5 россыпью из A-1 и 3 из короба хранения в B-1) и 2 шт. маркируемой
// воды (взята одна марка). Три короба отгрузки, второй пустой. Завершение без «не хватает» по
// воде — отказ со списком; с отметкой — заказ «собран частично», пустой короб убран, третий стал
// вторым, остаток переехал в `ОТГРУЗКУ`, марка — в короб, короба — в `ОТГРУЗКУ`. Ярлык печатается
// один раз, повтор — с правом. Отгрузка не всех коробов — отказ; всех — товар и короба ушли со
// склада, марка отгружена. В журнале событий — взял, завершил, отгрузил.
func TestPickingComplete(t *testing.T) {
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
	cellA := scan(`INSERT INTO cells (warehouse_id,address) VALUES ($1,'A-1') RETURNING id::text`, wh)
	cellB := scan(`INSERT INTO cells (warehouse_id,address) VALUES ($1,'B-1') RETURNING id::text`, wh)
	shipping, err := repository.NewCellRepository(pool).EnsureShipping(ctx, pool, wh)
	if err != nil {
		t.Fatalf("EnsureShipping: %v", err)
	}
	user := scan(`INSERT INTO users (login,password_hash,full_name) VALUES ('90000047','x','Кладовщик') RETURNING id::text`)
	other := scan(`INSERT INTO users (login,password_hash,full_name) VALUES ('90000048','x','Другой') RETURNING id::text`)
	good := scan(`INSERT INTO goods (code,name,uom) VALUES ('16147','Лимонад','шт') RETURNING id::text`)
	marked := scan(`INSERT INTO goods (code,name,uom,cz_marked) VALUES ('16149','Вода','шт',true) RETURNING id::text`)
	batch := scan(`INSERT INTO batches (good_id,production_date) VALUES ($1,'2026-10-01') RETURNING id::text`, good)
	mbatch := scan(`INSERT INTO batches (good_id,production_date) VALUES ($1,'2026-10-01') RETURNING id::text`, marked)
	main := scan(`SELECT id::text FROM internal_warehouses WHERE is_default`)
	stock := func(cell, good, batch, qty string) {
		exec(`INSERT INTO stock (cell_id,good_id,batch_id,qty,internal_warehouse_id) VALUES ($1,$2,$3,$4,$5)`,
			cell, good, batch, qty, main)
	}
	stock(cellA, good, batch, "20")
	stock(cellB, good, batch, "6")
	stock(cellA, marked, mbatch, "2")
	storage := scan(`INSERT INTO load_units (id,kind,cell_id,status) VALUES (gen_random_uuid(),'box',$1,'placed') RETURNING id::text`, cellB)
	exec(`INSERT INTO lu_content (load_unit_id,good_id,batch_id,qty) VALUES ($1,$2,$3,6)`, storage, good, batch)
	const mark1, mark2 = "0104600000000017215DONE1", "0104600000000017215DONE2"
	for _, cis := range []string{mark1, mark2} {
		exec(`INSERT INTO cz_marks (cis,good_id,batch_id,cell_id,internal_warehouse_id) VALUES ($1,$2,$3,$4,$5)`,
			cis, marked, mbatch, cellA, main)
	}

	load := scan(`INSERT INTO picking_loads (warehouse_id,registry_date,file_name,uploaded_by)
		VALUES ($1,'2026-11-09','Реестр.xlsx',$2) RETURNING id::text`, wh, user)
	order := scan(`INSERT INTO picking_orders (warehouse_id,registry_date,invoice_number,order_number,created_load_id,updated_load_id)
		VALUES ($1,'2026-11-09','20961','15512',$2,$2) RETURNING id::text`, wh, load)
	line := scan(`INSERT INTO picking_order_lines (order_id,line_no,good_code,good_name,good_id,plan_qty)
		VALUES ($1,1,'00000016147','Лимонад',$2,8) RETURNING id::text`, order, good)
	mline := scan(`INSERT INTO picking_order_lines (order_id,line_no,good_code,good_name,good_id,plan_qty)
		VALUES ($1,2,'00000016149','Вода',$2,2) RETURNING id::text`, order, marked)

	pk := repository.NewPickingRepository(pool)
	if err := pk.TakeOrder(ctx, order, user, 0); err != nil {
		t.Fatalf("взять заказ: %v", err)
	}
	box1, box2, box3 := uuid.NewString(), uuid.NewString(), uuid.NewString()
	for _, b := range []string{box1, box2, box3} {
		if _, err := pk.AddBox(ctx, order, user, b); err != nil {
			t.Fatalf("короб отгрузки: %v", err)
		}
	}
	ops := repository.NewOperationsRepository(pool)
	pick := func(in repository.PickingPickInput) {
		t.Helper()
		in.PickID, in.OrderID, in.PickedBy, in.ProductionDate = uuid.NewString(), order, user, "2026-10-01"
		if _, err := ops.PickingPick(ctx, uuid.NewString(), in); err != nil {
			t.Fatalf("пик: %v", err)
		}
	}
	pick(repository.PickingPickInput{LineID: line, BoxID: box1, SourceCellID: cellA, Qty: decimal.NewFromInt(5)})
	pick(repository.PickingPickInput{LineID: line, BoxID: box1, SourceLoadUnitID: storage, Qty: decimal.NewFromInt(3)})
	pick(repository.PickingPickInput{LineID: mline, BoxID: box3, SourceCellID: cellA, Qty: decimal.NewFromInt(1),
		Marks: []string{mark1}})

	// Не у своего исполнителя и с недособранной водой без «не хватает» — отказ.
	if _, err := pk.CompleteOrder(ctx, order, other); !errors.Is(err, model.ErrPickingOrderNotYours) {
		t.Fatalf("чужой заказ: %v", err)
	}
	var lerr *model.PickingLinesError
	if _, err := pk.CompleteOrder(ctx, order, user); !errors.As(err, &lerr) || len(lerr.Incomplete) != 1 || lerr.Incomplete[0] != "Вода" {
		t.Fatalf("недособрано: %v", err)
	}
	if _, err := pk.MarkShortage(ctx, order, mline, user, true); err != nil {
		t.Fatalf("не хватает: %v", err)
	}

	s, err := pk.CompleteOrder(ctx, order, user)
	if err != nil {
		t.Fatalf("завершить: %v", err)
	}
	if s.Status != model.PickingStatusPicked || !s.IsPartial || len(s.Boxes) != 2 ||
		s.Boxes[0].LoadUnitID != box1 || s.Boxes[1].LoadUnitID != box3 || s.Boxes[1].Seq != 2 ||
		!s.Qty.Equal(decimal.NewFromInt(9)) {
		t.Fatalf("собранный заказ: %+v", s)
	}
	if v := scan(`SELECT (dropped_at IS NOT NULL)::text FROM picking_boxes WHERE load_unit_id = $1`, box2); v != "true" {
		t.Fatalf("пустой короб не убран")
	}
	qty := func(cell, g string) string {
		return scan(`SELECT coalesce(sum(qty), 0)::int::text FROM stock WHERE cell_id = $1 AND good_id = $2`, cell, g)
	}
	if a, b, sh, msh := qty(cellA, good), qty(cellB, good), qty(shipping, good), qty(shipping, marked); a != "15" || b != "3" || sh != "8" || msh != "1" {
		t.Fatalf("остаток после завершения: A-1 %s, B-1 %s, ОТГРУЗКА %s и %s", a, b, sh, msh)
	}
	if v := scan(`SELECT qty::int::text FROM lu_content WHERE load_unit_id = $1`, storage); v != "3" {
		t.Fatalf("короб хранения: %s", v)
	}
	if v := scan(`SELECT qty::int::text FROM lu_content WHERE load_unit_id = $1`, box1); v != "8" {
		t.Fatalf("короб отгрузки 1: %s", v)
	}
	if v := scan(`SELECT load_unit_id::text FROM cz_marks WHERE cis = $1`, mark1); v != box3 {
		t.Fatalf("марка не в коробе отгрузки: %s", v)
	}
	if v := scan(`SELECT count(*)::text FROM load_units WHERE id = ANY($1::uuid[]) AND cell_id = $2 AND status = 'placed'`,
		[]string{box1, box3}, shipping); v != "2" {
		t.Fatalf("короба не в ОТГРУЗКЕ: %s", v)
	}
	if v := scan(`SELECT count(*)::text FROM picking_picks WHERE order_id = $1 AND state = 'moved'`, order); v != "3" {
		t.Fatalf("перенесённых пиков %s", v)
	}

	// Ярлыки: первый раз — без права, повтор — только с правом.
	if _, err := pk.PrintLabels(ctx, order, []string{box1, box3}, false); err != nil {
		t.Fatalf("ярлыки: %v", err)
	}
	if _, err := pk.PrintLabels(ctx, order, []string{box3}, false); !errors.Is(err, model.ErrPickingReprintDenied) {
		t.Fatalf("повтор без права: %v", err)
	}
	if s, err := pk.PrintLabels(ctx, order, []string{box3}, true); err != nil || s.Boxes[1].LabelsPrinted != 2 {
		t.Fatalf("повтор с правом: %+v, %v", s, err)
	}
	if _, err := pk.PrintLabels(ctx, order, []string{box2}, true); !errors.Is(err, model.ErrPickingShipBoxes) {
		t.Fatalf("ярлык убранного короба: %v", err)
	}

	// Отгрузка: не все короба — отказ; все — товар ушёл, марка отгружена; повтор — не ошибка.
	if _, err := pk.ShipOrder(ctx, order, user, []string{box1}); !errors.Is(err, model.ErrPickingShipBoxes) {
		t.Fatalf("не все короба: %v", err)
	}
	s, err = pk.ShipOrder(ctx, order, user, []string{box3, box1})
	if err != nil || s.Status != model.PickingStatusShipped || !s.Boxes[0].Shipped {
		t.Fatalf("отгрузить: %+v, %v", s, err)
	}
	if sh, msh := qty(shipping, good), qty(shipping, marked); sh != "0" || msh != "0" {
		t.Fatalf("остаток ОТГРУЗКИ после отгрузки: %s и %s", sh, msh)
	}
	if v := scan(`SELECT status FROM cz_marks WHERE cis = $1`, mark1); v != "shipped" {
		t.Fatalf("марка: %s", v)
	}
	if v := scan(`SELECT count(*)::text FROM load_units WHERE id = ANY($1::uuid[]) AND cell_id IS NULL AND status = 'shipped'`,
		[]string{box1, box3}); v != "2" {
		t.Fatalf("короба не отгружены: %s", v)
	}
	if _, err := pk.ShipOrder(ctx, order, user, []string{box1, box3}); err != nil {
		t.Fatalf("повтор отгрузки: %v", err)
	}
	if v := scan(`SELECT string_agg(kind || coalesce(':' || boxes || ':' || qty::int, ''), ',' ORDER BY seq)
		FROM picking_order_events WHERE order_id = $1`, order); v != "taken,completed:2:9,shipped:2:9" {
		t.Fatalf("журнал событий: %s", v)
	}
}

// TestPickingEvents — журнал событий взятия, отказа, перехвата зависшего и снятия старшим (P9-07).
func TestPickingEvents(t *testing.T) {
	pool := testutil.StartPostgres(t)
	ctx := context.Background()
	scan := func(sql string, args ...any) string {
		t.Helper()
		var v string
		mustScan(t, pool, sql, &v, args...)
		return v
	}
	wh := scan(`INSERT INTO warehouses (code,name) VALUES ('SHB','Шабулина') RETURNING id::text`)
	ann := scan(`INSERT INTO users (login,password_hash,full_name) VALUES ('90000049','x','Анна') RETURNING id::text`)
	bob := scan(`INSERT INTO users (login,password_hash,full_name) VALUES ('90000050','x','Борис') RETURNING id::text`)
	lead := scan(`INSERT INTO users (login,password_hash,full_name) VALUES ('90000051','x','Старший') RETURNING id::text`)
	load := scan(`INSERT INTO picking_loads (warehouse_id,registry_date,file_name,uploaded_by)
		VALUES ($1,'2026-11-09','Реестр.xlsx',$2) RETURNING id::text`, wh, ann)
	order := scan(`INSERT INTO picking_orders (warehouse_id,registry_date,invoice_number,order_number,created_load_id,updated_load_id)
		VALUES ($1,'2026-11-09','20961','15512',$2,$2) RETURNING id::text`, wh, load)

	pk := repository.NewPickingRepository(pool)
	steps := []func() error{
		func() error { return pk.TakeOrder(ctx, order, ann, 0) },
		func() error { return pk.ReleaseOrder(ctx, order, ann) },
		func() error { return pk.TakeOrder(ctx, order, ann, 0) },
		// Зависший (срок 0 — сразу) у Анны берёт Борис.
		func() error { return pk.TakeOrder(ctx, order, bob, 0) },
		func() error { return pk.ForceReleaseOrder(ctx, order, lead) },
	}
	for i, step := range steps {
		if err := step(); err != nil {
			t.Fatalf("шаг %d: %v", i, err)
		}
	}
	got := scan(`SELECT string_agg(e.kind || ':' || u.full_name || coalesce('<' || pu.full_name, ''), ',' ORDER BY e.seq)
		FROM picking_order_events e JOIN users u ON u.id = e.user_id LEFT JOIN users pu ON pu.id = e.prev_user_id
		WHERE e.order_id = $1`, order)
	if want := "taken:Анна,released:Анна,taken:Анна,taken_over:Борис<Анна,released_by_lead:Старший<Борис"; got != want {
		t.Fatalf("журнал: %s", got)
	}
}

// TestPickingCompleteAllShort — «не хватает» по всем позициям: ничего не взято, завершение без
// отметки - отказ «завершать нечего»; с отметкой - заказ собран частично без коробов (пустой короб
// убран), отгрузка пустым набором закрывает его, короб с ярлыком - отказ.
func TestPickingCompleteAllShort(t *testing.T) {
	pool := testutil.StartPostgres(t)
	ctx := context.Background()
	scan := func(sql string, args ...any) string {
		t.Helper()
		var v string
		mustScan(t, pool, sql, &v, args...)
		return v
	}
	wh := scan(`INSERT INTO warehouses (code,name) VALUES ('SHB','Шабулина') RETURNING id::text`)
	user := scan(`INSERT INTO users (login,password_hash,full_name) VALUES ('90000052','x','Кладовщик') RETURNING id::text`)
	good := scan(`INSERT INTO goods (code,name,uom) VALUES ('16150','Чипсы','шт') RETURNING id::text`)
	load := scan(`INSERT INTO picking_loads (warehouse_id,registry_date,file_name,uploaded_by)
		VALUES ($1,'2026-11-09','Реестр.xlsx',$2) RETURNING id::text`, wh, user)
	order := scan(`INSERT INTO picking_orders (warehouse_id,registry_date,invoice_number,order_number,created_load_id,updated_load_id)
		VALUES ($1,'2026-11-09','21048','15787',$2,$2) RETURNING id::text`, wh, load)
	line := scan(`INSERT INTO picking_order_lines (order_id,line_no,good_code,good_name,good_id,plan_qty)
		VALUES ($1,1,'00000016150','Чипсы',$2,1) RETURNING id::text`, order, good)

	pk := repository.NewPickingRepository(pool)
	if err := pk.TakeOrder(ctx, order, user, 0); err != nil {
		t.Fatalf("взять заказ: %v", err)
	}
	box := uuid.NewString()
	if _, err := pk.AddBox(ctx, order, user, box); err != nil {
		t.Fatalf("короб отгрузки: %v", err)
	}
	var lerr *model.PickingLinesError
	if _, err := pk.CompleteOrder(ctx, order, user); !errors.As(err, &lerr) {
		t.Fatalf("без отметки: %v", err)
	}
	if _, err := pk.MarkShortage(ctx, order, line, user, true); err != nil {
		t.Fatalf("не хватает: %v", err)
	}
	s, err := pk.CompleteOrder(ctx, order, user)
	if err != nil || s.Status != model.PickingStatusPicked || !s.IsPartial || len(s.Boxes) != 0 {
		t.Fatalf("завершить без коробов: %+v, %v", s, err)
	}
	if _, err := pk.ShipOrder(ctx, order, user, []string{box}); !errors.Is(err, model.ErrPickingShipBoxes) {
		t.Fatalf("отгрузка убранного короба: %v", err)
	}
	s, err = pk.ShipOrder(ctx, order, user, nil)
	if err != nil || s.Status != model.PickingStatusShipped {
		t.Fatalf("отгрузка без коробов: %+v, %v", s, err)
	}
	// «Завершённые» на ТСД: отгруженный - в списке своей даты накладной, другой даты - нет.
	if list, err := pk.ShippedOrders(ctx, user, time.Date(2026, 11, 9, 0, 0, 0, 0, time.UTC)); err != nil ||
		len(list) != 1 || list[0].ID != order || list[0].Status != model.PickingStatusShipped {
		t.Fatalf("отгруженные за дату: %+v, %v", list, err)
	}
	if list, err := pk.ShippedOrders(ctx, user, time.Date(2026, 11, 10, 0, 0, 0, 0, time.UTC)); err != nil || len(list) != 0 {
		t.Fatalf("отгруженные другой даты: %+v, %v", list, err)
	}
	got := scan(`SELECT string_agg(kind || ':' || coalesce(boxes::text, '-'), ',' ORDER BY seq)
		FROM picking_order_events WHERE order_id = $1`, order)
	if want := "taken:-,completed:0,shipped:0"; got != want {
		t.Fatalf("журнал: %s", got)
	}
}
