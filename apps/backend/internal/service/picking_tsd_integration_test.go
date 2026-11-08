package service

import (
	"context"
	"errors"
	"testing"

	"craftwms/internal/model"
	"craftwms/internal/repository"
	"craftwms/internal/testutil"
)

// TestPickingTSD_flow — цикл сборки на ТСД по живой базе (P9-04): список, взять, повтор, чужой
// заказ, зависший перехват, отказаться, короба отгрузки «N» с повтором и чужим ярлыком,
// «не хватает» с пересчётом позиции (ячейки товара плюс ячейка реестра, основание — заказ, второй
// не заводится), отказы удалённого и нераспознанного заказа.
func TestPickingTSD_flow(t *testing.T) {
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
	cellR := scan(`INSERT INTO cells (warehouse_id,address) VALUES ($1,'R-1') RETURNING id::text`, wh)
	ann := scan(`INSERT INTO users (login,password_hash,full_name) VALUES ('90000044','x','Анна') RETURNING id::text`)
	bob := scan(`INSERT INTO users (login,password_hash,full_name) VALUES ('90000045','x','Борис') RETURNING id::text`)
	good := scan(`INSERT INTO goods (code,name,uom) VALUES ('16147','Лимонад','шт') RETURNING id::text`)
	ghost := scan(`INSERT INTO goods (code,name,uom) VALUES ('16148','Квас','шт') RETURNING id::text`)
	batch := scan(`INSERT INTO batches (good_id,production_date) VALUES ($1,'2026-10-01') RETURNING id::text`, good)
	main := scan(`SELECT id::text FROM internal_warehouses WHERE is_default`)
	exec(`INSERT INTO stock (cell_id,good_id,batch_id,qty,internal_warehouse_id) VALUES ($1,$2,$3,3,$4)`, cellA, good, batch, main)

	load := scan(`INSERT INTO picking_loads (warehouse_id,registry_date,file_name,uploaded_by)
		VALUES ($1,'2026-11-09','Реестр.xlsx',$2) RETURNING id::text`, wh, ann)
	order := func(number, date string) string {
		return scan(`INSERT INTO picking_orders (warehouse_id,registry_date,invoice_number,order_number,client,
			    created_load_id,updated_load_id) VALUES ($1,$2,'20961',$3,'ИП Суслова',$4,$4) RETURNING id::text`,
			wh, date, number, load)
	}
	o1 := order("15512", "2026-11-09")
	o2 := order("15513", "2026-11-08") // дата раньше — в списке первым
	line := scan(`INSERT INTO picking_order_lines (order_id,line_no,good_code,good_id,cell_id,registry_cell,plan_qty)
		VALUES ($1,1,'00000016147',$2,$3,'R-1',10) RETURNING id::text`, o1, good, cellR)
	ghostLine := scan(`INSERT INTO picking_order_lines (order_id,line_no,good_code,good_id,plan_qty)
		VALUES ($1,2,'00000016148',$2,1) RETURNING id::text`, o1, ghost)

	svc := NewPickingTaskService(repository.NewPickingRepository(pool))

	// Список: оба заказа, старшая дата первой, никто не взял.
	list, err := svc.Orders(ctx, ann)
	if err != nil || len(list) != 2 || list[0].ID != o2 || list[1].Lines != 2 || list[1].Mine || list[1].Busy {
		t.Fatalf("список: %+v, %v", list, err)
	}

	// Анна берёт заказ, повтор — не ошибка; Борис видит его занятым и взять не может.
	if err := svc.Take(ctx, o1, ann); err != nil {
		t.Fatalf("взять: %v", err)
	}
	if err := svc.Take(ctx, o1, ann); err != nil {
		t.Fatalf("повтор взятия: %v", err)
	}
	if err := svc.Take(ctx, o1, bob); !errors.Is(err, model.ErrPickingOrderTaken) {
		t.Fatalf("чужой заказ: %v", err)
	}
	list, _ = svc.Orders(ctx, bob)
	if !list[1].Busy || list[1].AssigneeName != "Анна" {
		t.Fatalf("занятый для Бориса: %+v", list[1])
	}
	if err := svc.Release(ctx, o1, bob); !errors.Is(err, model.ErrPickingOrderTaken) {
		t.Fatalf("отказ от чужого: %v", err)
	}
	if _, err := svc.AddBox(ctx, o1, bob, "11111111-1111-4111-8111-111111111111"); !errors.Is(err, model.ErrPickingOrderNotYours) {
		t.Fatalf("короб в чужом заказе: %v", err)
	}

	// Короба отгрузки: номера по порядку, повтор отдаёт тот же номер, ярлык другого короба — отказ.
	box1, box2 := "22222222-2222-4222-8222-222222222222", "33333333-3333-4333-8333-333333333333"
	if seq, err := svc.AddBox(ctx, o1, ann, box1); err != nil || seq != 1 {
		t.Fatalf("короб 1: %d, %v", seq, err)
	}
	if seq, err := svc.AddBox(ctx, o1, ann, box2); err != nil || seq != 2 {
		t.Fatalf("короб 2: %d, %v", seq, err)
	}
	if seq, err := svc.AddBox(ctx, o1, ann, box1); err != nil || seq != 1 {
		t.Fatalf("повтор короба 1: %d, %v", seq, err)
	}
	storage := scan(`INSERT INTO load_units (id,kind,cell_id,status) VALUES (gen_random_uuid(),'box',$1,'placed') RETURNING id::text`, cellA)
	if _, err := svc.AddBox(ctx, o1, ann, storage); !errors.Is(err, model.ErrPickingBoxForeign) {
		t.Fatalf("ярлык короба хранения: %v", err)
	}
	if _, err := svc.AddBox(ctx, o1, ann, "не ярлык"); !errors.Is(err, model.ErrPickingBoxID) {
		t.Fatalf("ярлык не UUID: %v", err)
	}
	task, err := svc.Task(ctx, o1)
	if err != nil || len(task.Order.Boxes) != 2 || task.Order.Boxes[1].Seq != 2 {
		t.Fatalf("короба в заказе: %+v, %v", task.Order.Boxes, err)
	}

	// «Не хватает»: пересчёт товара в A-1 (там остаток) и R-1 (ячейка реестра), основание — заказ.
	res, err := svc.MarkShortage(ctx, o1, line, ann, true)
	if err != nil || !res.Created || res.StocktakeNumber == nil {
		t.Fatalf("не хватает: %+v, %v", res, err)
	}
	var cells, tasks int
	var basis string
	if err := pool.QueryRow(ctx, `
		SELECT (SELECT count(*) FROM stocktake_cells sc WHERE sc.stocktake_id = st.id AND sc.cell_id IN ($2, $3)),
		       (SELECT count(*) FROM warehouse_tasks wt WHERE wt.stocktake_id = st.id),
		       st.picking_order_id::text
		FROM stocktakes st WHERE st.number = $1`, *res.StocktakeNumber, cellA, cellR).Scan(&cells, &tasks, &basis); err != nil {
		t.Fatalf("пересчёт по нехватке: %v", err)
	}
	if cells != 2 || tasks != 1 || basis != o1 {
		t.Fatalf("пересчёт: ячеек %d, заданий %d, основание %s", cells, tasks, basis)
	}
	again, err := svc.MarkShortage(ctx, o1, line, ann, true)
	if err != nil || again.Created || again.StocktakeNumber == nil || *again.StocktakeNumber != *res.StocktakeNumber {
		t.Fatalf("повтор нехватки завёл второй пересчёт: %+v, %v", again, err)
	}
	// Товара нет нигде и ячейки реестра нет — считать негде, отметка ставится без пересчёта.
	none, err := svc.MarkShortage(ctx, o1, ghostLine, ann, true)
	if err != nil || none.StocktakeNumber != nil {
		t.Fatalf("нехватка без ячеек: %+v, %v", none, err)
	}
	if _, err := svc.MarkShortage(ctx, o1, line, ann, false); err != nil {
		t.Fatalf("снять отметку: %v", err)
	}
	if _, err := svc.MarkShortage(ctx, o1, "44444444-4444-4444-8444-444444444444", ann, true); !errors.Is(err, model.ErrPickingLineNotFound) {
		t.Fatalf("чужая строка: %v", err)
	}

	// Зависший заказ перехватывает другой кладовщик; отказ возвращает заказ в «новый».
	exec(`UPDATE picking_orders SET last_activity_at = now() - interval '9 hours' WHERE id = $1`, o1)
	if err := svc.Take(ctx, o1, bob); err != nil {
		t.Fatalf("перехват зависшего: %v", err)
	}
	if err := svc.Release(ctx, o1, bob); err != nil {
		t.Fatalf("отказаться: %v", err)
	}
	if err := svc.Release(ctx, o1, bob); err != nil {
		t.Fatalf("повтор отказа: %v", err)
	}
	if st := scan(`SELECT status FROM picking_orders WHERE id = $1`, o1); st != model.PickingStatusNew {
		t.Fatalf("после отказа статус %s", st)
	}

	// Удалённый в 1С и с нераспознанными позициями не берутся и не видны в списке.
	exec(`UPDATE picking_orders SET deleted_at = now() WHERE id = $1`, o2)
	if err := svc.Take(ctx, o2, ann); !errors.Is(err, model.ErrPickingOrderDeleted) {
		t.Fatalf("удалённый: %v", err)
	}
	if list, _ := svc.Orders(ctx, ann); len(list) != 1 {
		t.Fatalf("удалённый в списке: %+v", list)
	}
	exec(`UPDATE picking_orders SET has_unknown = true WHERE id = $1`, o1)
	if err := svc.Take(ctx, o1, ann); !errors.Is(err, model.ErrPickingOrderUnknown) {
		t.Fatalf("нераспознанные позиции: %v", err)
	}
	if err := svc.Take(ctx, "не uuid", ann); !errors.Is(err, model.ErrPickingOrderNotFound) {
		t.Fatalf("не UUID: %v", err)
	}
}
