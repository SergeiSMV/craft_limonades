package service

import (
	"bytes"
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/xuri/excelize/v2"

	"craftwms/internal/model"
	"craftwms/internal/repository"
	"craftwms/internal/testutil"
)

// TestPickingPortal_live — раздел портала «Сборка-отгрузка» по живой базе (P8-03): заказы на дату
// (удалённый — с пометкой, в конце), детали план/факт с партией, марками и коробом, убранная
// строка, правки реестра, снятие заказа с исполнителя (пики и короба остаются, прежний
// кладовщик — «не у вас в работе»), собранный не снимается, выгрузка Excel по листам.
func TestPickingPortal_live(t *testing.T) {
	pool := testutil.StartPostgres(t)
	ctx := context.Background()
	scan := func(sql string, args ...any) string {
		t.Helper()
		var v string
		if err := pool.QueryRow(ctx, sql, args...).Scan(&v); err != nil {
			t.Fatalf("%s: %v", sql, err)
		}
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
	ann := scan(`INSERT INTO users (login,password_hash,full_name) VALUES ('90000054','x','Анна') RETURNING id::text`)
	good := scan(`INSERT INTO goods (code,name,uom,cz_marked) VALUES ('16147','Лимонад','шт',true) RETURNING id::text`)
	batch := scan(`INSERT INTO batches (good_id,production_date) VALUES ($1,'2026-10-01') RETURNING id::text`, good)
	main := scan(`SELECT id::text FROM internal_warehouses WHERE is_default`)
	exec(`INSERT INTO stock (cell_id,good_id,batch_id,qty,internal_warehouse_id) VALUES ($1,$2,$3,5,$4)`, cellA, good, batch, main)
	exec(`INSERT INTO cz_marks (cis, good_id, batch_id, cell_id, internal_warehouse_id) VALUES ('0104600000000017215abc',$1,$2,$3,$4)`,
		good, batch, cellA, main)

	load := scan(`INSERT INTO picking_loads (warehouse_id,registry_date,file_name,uploaded_by)
		VALUES ($1,'2026-11-09','Реестр.xlsx',$2) RETURNING id::text`, wh, ann)
	order := func(number, date string) string {
		return scan(`INSERT INTO picking_orders (warehouse_id,registry_date,invoice_number,order_number,client,
			    created_load_id,updated_load_id) VALUES ($1,$2,'20961',$3,'ИП Суслова',$4,$4) RETURNING id::text`,
			wh, date, number, load)
	}
	o1 := order("15512", "2026-11-09")
	gone := order("15513", "2026-11-09")
	order("15514", "2026-11-10") // другая дата — не в списке
	exec(`UPDATE picking_orders SET deleted_at = now() WHERE id = $1`, gone)
	line := scan(`INSERT INTO picking_order_lines (order_id,line_no,good_code,good_name,good_id,batch_date,registry_cell,plan_qty)
		VALUES ($1,1,'00000016147','Лимонад 1С',$2,'2026-10-01','A-1',3) RETURNING id::text`, o1, good)
	exec(`INSERT INTO picking_order_lines (order_id,line_no,good_code,good_name,plan_qty,removed_at)
		VALUES ($1,2,'00000016148','Квас',2,now())`, o1)
	exec(`INSERT INTO picking_order_changes (order_id,load_id,kind,good_code,good_name,old_qty,new_qty,order_status)
		VALUES ($1,$2,'qty_changed','00000016147','Лимонад 1С',2,3,'new')`, o1, load)

	tsd := NewPickingTaskService(repository.NewPickingRepository(pool))
	if err := tsd.Take(ctx, o1, ann); err != nil {
		t.Fatalf("взять: %v", err)
	}
	box := "22222222-2222-4222-8222-222222222222"
	if _, err := tsd.AddBox(ctx, o1, ann, box); err != nil {
		t.Fatalf("короб: %v", err)
	}
	pick := scan(`INSERT INTO picking_picks (order_id,line_id,box_id,good_id,batch_id,source_cell_id,internal_warehouse_id,qty,picked_by)
		VALUES ($1,$2,$3,$4,$5,$6,$7,1,$8) RETURNING id::text`, o1, line, box, good, batch, cellA, main, ann)
	exec(`INSERT INTO picking_pick_marks (pick_id,cis) VALUES ($1,'0104600000000017215abc')`, pick)

	svc := NewPickingPortalService(repository.NewPickingRepository(pool), repository.NewWarehouseRepository(pool))
	date := time.Date(2026, 11, 9, 0, 0, 0, 0, time.UTC)

	// Список даты: живой заказ первым, удалённый — в конце с пометкой; другая дата не видна.
	list, err := svc.Orders(ctx, "SHB", date)
	if err != nil || len(list) != 2 || list[0].ID != o1 || !list[1].Deleted {
		t.Fatalf("список: %+v, %v", list, err)
	}
	if o := list[0]; o.Status != model.PickingStatusInProgress || o.AssigneeName != "Анна" || o.TakenAt == nil ||
		o.Lines != 1 || o.PlanQty != 3 || o.FactQty.IntPart() != 1 || o.Boxes != 1 {
		t.Fatalf("заказ в списке: %+v", o)
	}
	if _, err := svc.Orders(ctx, "NOPE", date); !errors.Is(err, repository.ErrNotFound) {
		t.Fatalf("неизвестный склад: %v", err)
	}

	// Детали: строка с фактом (партия, ячейка, короб 1, марка), убранная строка, правка, короб.
	d, err := svc.Order(ctx, o1)
	if err != nil || len(d.Lines) != 2 || len(d.Boxes) != 1 || len(d.Changes) != 1 {
		t.Fatalf("детали: %+v, %v", d, err)
	}
	l := d.Lines[0]
	if !l.CZMarked || l.CellAddress != "" || l.RegistryCell != "A-1" || len(l.Facts) != 1 || !d.Lines[1].Removed {
		t.Fatalf("строки: %+v", d.Lines)
	}
	if f := l.Facts[0]; f.BoxSeq != 1 || f.CellAddress != "A-1" || f.State != "picking" || f.PickedBy != "Анна" ||
		len(f.Marks) != 1 || f.BatchDate.Format(time.DateOnly) != "2026-10-01" {
		t.Fatalf("факт: %+v", f)
	}
	if _, err := svc.Order(ctx, "не uuid"); !errors.Is(err, model.ErrPickingOrderNotFound) {
		t.Fatalf("не UUID: %v", err)
	}
	if _, err := svc.Order(ctx, "44444444-4444-4444-8444-444444444444"); !errors.Is(err, model.ErrPickingOrderNotFound) {
		t.Fatalf("нет заказа: %v", err)
	}

	// Снятие: заказ «новый» без исполнителя, пик и короб на месте; повтор — не ошибка; Анна на
	// следующем действии узнаёт, что заказ не у неё.
	if err := svc.Release(ctx, o1); err != nil {
		t.Fatalf("снять: %v", err)
	}
	if err := svc.Release(ctx, o1); err != nil {
		t.Fatalf("повтор снятия: %v", err)
	}
	if st := scan(`SELECT status || coalesce(assignee_id::text, '-') FROM picking_orders WHERE id = $1`, o1); st != "new-" {
		t.Fatalf("после снятия: %s", st)
	}
	if n := scan(`SELECT count(*)::text FROM picking_picks WHERE order_id = $1 AND state = 'picking'`, o1); n != "1" {
		t.Fatalf("пиков после снятия %s", n)
	}
	if _, err := tsd.AddBox(ctx, o1, ann, "33333333-3333-4333-8333-333333333333"); !errors.Is(err, model.ErrPickingOrderNotYours) {
		t.Fatalf("прежний кладовщик: %v", err)
	}
	exec(`UPDATE picking_orders SET status = 'picked', picked_by = $2, picked_at = now() WHERE id = $1`, o1, ann)
	if err := svc.Release(ctx, o1); !errors.Is(err, model.ErrPickingOrderClosed) {
		t.Fatalf("снять собранный: %v", err)
	}

	// Выгрузка: лист «Сборка» — заказ блоком с позициями (план, факт по партии и ячейке, короб,
	// комментарий, марка), «Заказы» — строка на заказ, «Правки».
	data, name, err := svc.ExportXLSX(ctx, "SHB", date)
	if err != nil || name != "sborka-SHB-20261109.xlsx" {
		t.Fatalf("выгрузка: %s, %v", name, err)
	}
	f, err := excelize.OpenReader(bytes.NewReader(data))
	if err != nil {
		t.Fatalf("разбор выгрузки: %v", err)
	}
	defer func() { _ = f.Close() }()
	if got := f.GetSheetList(); len(got) != 3 || got[0] != "Сборка" {
		t.Fatalf("листы: %v", got)
	}
	sheet, _ := f.GetRows("Сборка")
	find := func(col int, value string) []string {
		for _, r := range sheet {
			if len(r) > col && r[col] == value {
				return r
			}
		}
		t.Fatalf("на листе «Сборка» нет строки с %q в колонке %d: %v", value, col, sheet)
		return nil
	}
	number := "СБ-" + scan(`SELECT lpad(number::text, 6, '0') FROM picking_orders WHERE id = $1`, o1)
	find(2, number)
	find(2, "15512")
	if r := find(0, "Накладная"); !strings.HasSuffix(r[2], " от 09.11.2026") {
		t.Errorf("накладная с датой реестра: %v", r)
	}
	if r := find(0, "Исполнитель"); !strings.HasPrefix(r[2], "Анна, собран ") {
		t.Errorf("исполнитель собранного: %v", r)
	}
	if r := find(0, "Правка реестра"); !strings.Contains(r[2], "2 → 3") {
		t.Errorf("правка в шапке: %v", r)
	}
	if r := find(1, "00000016147"); len(r) < 14 || r[2] != "Лимонад 1С" || r[5] != "01.10.2026" || r[6] != "3" ||
		r[7] != "1" || r[8] != "01.10.2026" || r[9] != "A-1" || r[10] != "Короб 1" ||
		r[12] != "ячейки реестра нет в WMS; в сборке 1" || r[13] != "0104600000000017215abc" {
		t.Errorf("позиция с фактом: %q", r)
	}
	if r := find(1, "00000016148"); len(r) < 13 || r[12] != "нет в номенклатуре; убрана реестром" || r[5] != "любая" {
		t.Errorf("убранная позиция: %q", r)
	}
	orders, _ := f.GetRows("Заказы")
	if len(orders) != 5 || orders[3][7] != "собран" || orders[4][8] != "удалён в 1С" {
		t.Errorf("заказы выгрузки: %v", orders)
	}
	if changes, _ := f.GetRows("Правки"); len(changes) != 2 {
		t.Errorf("правки выгрузки: %v", changes)
	}
}
