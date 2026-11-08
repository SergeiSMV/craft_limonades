package service

import (
	"context"
	"errors"
	"testing"

	"craftwms/internal/repository"
	"craftwms/internal/testutil"
)

// TestPickingTask_live — подбор заказа по живой базе (P9-03).
//
// Склад: 100 шт. ранней партии в ПРИЁМКЕ (служебная - не источник), 10 шт. в «Браке» (сборка не
// разрешена), 3 шт. ранней партии на полу F-Н-П; в ячейке реестра A-1 партия реестра - 9 шт., из
// них 4 в коробе хранения, а 2 шт. россыпи уже «в сборке» у другого заказа. Строка с партией
// реестра на 8 шт. берёт россыпь A-1 (3), короб A-1 (4) и добирает 1 шт. ранней партией с пола;
// строка без партии получает оставшиеся 2 шт. пола. Убранная реестром строка подбора не получает.
func TestPickingTask_live(t *testing.T) {
	pool := testutil.StartPostgres(t)
	ctx := context.Background()
	scan := func(sql string, args ...any) string {
		t.Helper()
		var id string
		if err := pool.QueryRow(ctx, sql, args...).Scan(&id); err != nil {
			t.Fatalf("%s: %v", sql, err)
		}
		return id
	}
	exec := func(sql string, args ...any) {
		t.Helper()
		if _, err := pool.Exec(ctx, sql, args...); err != nil {
			t.Fatalf("%s: %v", sql, err)
		}
	}

	wh := scan(`INSERT INTO warehouses (code,name) VALUES ('SHB','Шабулина') RETURNING id::text`)
	cell := func(address string, isDefault, isFloor, isShipping bool) string {
		return scan(`INSERT INTO cells (warehouse_id,address,is_default,is_floor_storage,is_shipping)
			VALUES ($1,$2,$3,$4,$5) RETURNING id::text`, wh, address, isDefault, isFloor, isShipping)
	}
	cellA := cell("A-1", false, false, false)
	cellB := cell("B-1", false, false, false)
	floor := cell("F-Н-П", false, true, false)
	receiving := cell("ПРИЁМКА", true, false, false)
	shipping := cell("ОТГРУЗКА", false, false, true)
	user := scan(`INSERT INTO users (login,password_hash,full_name) VALUES ('90000043','x','Кладовщик') RETURNING id::text`)
	good := scan(`INSERT INTO goods (code,name,uom) VALUES ('16147','Лимонад','шт') RETURNING id::text`)
	early := scan(`INSERT INTO batches (good_id,production_date) VALUES ($1,'2026-09-01') RETURNING id::text`, good)
	late := scan(`INSERT INTO batches (good_id,production_date) VALUES ($1,'2026-10-01') RETURNING id::text`, good)
	main := scan(`SELECT id::text FROM internal_warehouses WHERE is_default`)
	defect := scan(`SELECT id::text FROM internal_warehouses WHERE code = 'DEFECT'`)

	stock := func(cell, batch, iw, qty string) {
		exec(`INSERT INTO stock (cell_id,good_id,batch_id,qty,internal_warehouse_id) VALUES ($1,$2,$3,$4,$5)`,
			cell, good, batch, qty, iw)
	}
	stock(receiving, early, main, "100")
	stock(cellB, early, defect, "10")
	stock(floor, early, main, "3")
	stock(cellA, late, main, "9")
	box := scan(`INSERT INTO load_units (id,kind,cell_id,status) VALUES (gen_random_uuid(),'box',$1,'placed') RETURNING id::text`, cellA)
	exec(`INSERT INTO lu_content (load_unit_id,good_id,batch_id,qty) VALUES ($1,$2,$3,4)`, box, good, late)
	// Короб в ОТГРУЗКЕ - уже собранное, не источник.
	shipped := scan(`INSERT INTO load_units (id,kind,cell_id,status) VALUES (gen_random_uuid(),'box',$1,'closed') RETURNING id::text`, shipping)
	stock(shipping, early, main, "50")
	exec(`INSERT INTO lu_content (load_unit_id,good_id,batch_id,qty) VALUES ($1,$2,$3,50)`, shipped, good, early)

	load := scan(`INSERT INTO picking_loads (warehouse_id,registry_date,file_name,uploaded_by)
		VALUES ($1,'2026-11-09','Реестр.xlsx',$2) RETURNING id::text`, wh, user)
	order := func(number string) string {
		return scan(`INSERT INTO picking_orders (warehouse_id,registry_date,invoice_number,order_number,
			    created_load_id,updated_load_id) VALUES ($1,'2026-11-09','20961',$2,$3,$3) RETURNING id::text`,
			wh, number, load)
	}
	line := func(order string, no int, batch any, cell any, registryCell string, qty int, removed bool) string {
		return scan(`INSERT INTO picking_order_lines (order_id,line_no,good_code,good_id,batch_date,cell_id,registry_cell,
			    plan_qty,removed_at)
			VALUES ($1,$2,'00000016147',$3,$4,$5,$6,$7,CASE WHEN $8 THEN now() END) RETURNING id::text`,
			order, no, good, batch, cell, registryCell, qty, removed)
	}

	// Другой заказ уже взял 2 шт. россыпи A-1: они «в сборке».
	other := order("15500")
	otherLine := line(other, 1, nil, nil, "", 2, false)
	exec(`UPDATE picking_orders SET status='in_progress', assignee_id=$2, taken_at=now() WHERE id=$1`, other, user)
	shipBox := scan(`INSERT INTO load_units (id,kind) VALUES (gen_random_uuid(),'box') RETURNING id::text`)
	exec(`INSERT INTO picking_boxes (load_unit_id,order_id,seq,created_by) VALUES ($1,$2,1,$3)`, shipBox, other, user)
	exec(`INSERT INTO picking_picks (order_id,line_id,box_id,good_id,batch_id,source_cell_id,internal_warehouse_id,qty,picked_by)
		VALUES ($1,$2,$3,$4,$5,$6,$7,2,$8)`, other, otherLine, shipBox, good, late, cellA, main, user)

	target := order("15512")
	withBatch := line(target, 1, "2026-10-01", cellA, "А-1", 8, false)
	free := line(target, 2, nil, nil, "", 2, false)
	removed := line(target, 3, "2026-09-01", nil, "", 5, true)

	svc := NewPickingTaskService(repository.NewPickingRepository(pool))
	task, err := svc.Task(ctx, target)
	if err != nil {
		t.Fatalf("Task: %v", err)
	}
	if len(task.Lines) != 3 {
		t.Fatalf("строк %d, ждали 3", len(task.Lines))
	}
	got := map[string][]string{}
	for _, l := range task.Lines {
		if l.Suggestion == nil {
			got[l.Line.ID] = nil
			continue
		}
		for _, tk := range l.Suggestion.Takes {
			place := tk.Source.CellAddress
			if tk.Source.LoadUnitID != "" {
				place += "/короб"
			}
			got[l.Line.ID] = append(got[l.Line.ID], place+":"+tk.Source.BatchDate.Format("01")+":"+tk.Qty.String())
		}
	}
	wantBatch := []string{"A-1:10:3", "A-1/короб:10:4", "F-Н-П:09:1"}
	if !equalStrings(got[withBatch], wantBatch) {
		t.Errorf("строка с партией: %v, ждали %v", got[withBatch], wantBatch)
	}
	if w := []string{"F-Н-П:09:2"}; !equalStrings(got[free], w) {
		t.Errorf("строка без партии: %v, ждали %v", got[free], w)
	}
	if task.Lines[2].Line.ID != removed || task.Lines[2].Suggestion != nil {
		t.Errorf("убранная строка получила подбор: %+v", task.Lines[2].Suggestion)
	}
	sg := task.Lines[0].Suggestion
	if !sg.BatchSubstituted || !sg.CellSubstituted || !sg.Short.IsZero() {
		t.Errorf("замены строки с партией: партия %v ячейка %v нехватка %s", sg.BatchSubstituted, sg.CellSubstituted, sg.Short)
	}

	// Пик по строке уменьшает остаток подбора на взятое.
	targetBox := scan(`INSERT INTO load_units (id,kind) VALUES (gen_random_uuid(),'box') RETURNING id::text`)
	exec(`INSERT INTO picking_boxes (load_unit_id,order_id,seq,created_by) VALUES ($1,$2,1,$3)`, targetBox, target, user)
	exec(`INSERT INTO picking_picks (order_id,line_id,box_id,good_id,batch_id,source_cell_id,internal_warehouse_id,
		    qty,picked_by,state,moved_at)
		VALUES ($1,$2,$3,$4,$5,$6,$7,2,$8,'moved',now())`, target, free, targetBox, good, early, floor, main, user)
	task, err = svc.Task(ctx, target)
	if err != nil {
		t.Fatalf("Task после пика: %v", err)
	}
	if r := task.Lines[1].Suggestion.Remaining; !r.IsZero() {
		t.Errorf("строка без партии собрана, осталось %s", r)
	}

	// Отказы по состоянию заказа.
	exec(`UPDATE picking_orders SET has_unknown=true WHERE id=$1`, target)
	if _, err := svc.Task(ctx, target); !errors.Is(err, ErrPickingOrderUnknown) {
		t.Errorf("нераспознанные позиции: %v", err)
	}
	exec(`UPDATE picking_orders SET has_unknown=false, deleted_at=now() WHERE id=$1`, target)
	if _, err := svc.Task(ctx, target); !errors.Is(err, ErrPickingOrderDeleted) {
		t.Errorf("удалённый заказ: %v", err)
	}
	exec(`UPDATE picking_orders SET deleted_at=NULL, status='picked', picked_by=$2, picked_at=now() WHERE id=$1`, target, user)
	if _, err := svc.Task(ctx, target); !errors.Is(err, ErrPickingOrderClosed) {
		t.Errorf("собранный заказ: %v", err)
	}
	if _, err := svc.Task(ctx, "00000000-0000-0000-0000-000000000000"); !errors.Is(err, ErrPickingOrderNotFound) {
		t.Errorf("нет заказа: %v", err)
	}
}

func equalStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
