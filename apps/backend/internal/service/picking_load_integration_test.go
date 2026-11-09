package service

import (
	"bytes"
	"context"
	"errors"
	"testing"

	"craftwms/internal/model"
	"craftwms/internal/repository"
	"craftwms/internal/testutil"
)

// TestPickingLoad_flow — загрузка реестра в живую базу (P8-02): предпросмотр ничего не пишет и
// подсвечивает нехватку; загрузка заводит заказы; повторная загрузка той же даты удаляет
// пропавший заказ, а собранному с добавленным товаром возвращает дособор; третья загрузка того же
// файла ничего не меняет.
func TestPickingLoad_flow(t *testing.T) {
	pool := testutil.StartPostgres(t)
	ctx := context.Background()
	scan := func(sql string) string {
		t.Helper()
		var id string
		if err := pool.QueryRow(ctx, sql).Scan(&id); err != nil {
			t.Fatalf("%s: %v", sql, err)
		}
		return id
	}
	count := func(sql string) int {
		t.Helper()
		var n int
		if err := pool.QueryRow(ctx, sql).Scan(&n); err != nil {
			t.Fatalf("%s: %v", sql, err)
		}
		return n
	}
	wh := scan(`INSERT INTO warehouses (code,name) VALUES ('SHB','Шабулина') RETURNING id::text`)
	cell := scan(`INSERT INTO cells (warehouse_id,address) VALUES ('` + wh + `','M1-1-1-1') RETURNING id::text`)
	user := scan(`INSERT INTO users (login,password_hash,full_name) VALUES ('90000041','x','Оператор') RETURNING id::text`)
	// Код как его пишет импорт номенклатуры из .xls — числом, без ведущих нулей.
	good := scan(`INSERT INTO goods (code,name,uom) VALUES ('1','Сыр','шт') RETURNING id::text`)
	batch := scan(`INSERT INTO batches (good_id,production_date) VALUES ('` + good + `','2026-10-01') RETURNING id::text`)
	iwh := scan(`SELECT id::text FROM internal_warehouses WHERE is_default`)
	defect := scan(`SELECT id::text FROM internal_warehouses WHERE code = 'DEFECT'`)
	// 3 шт. в «Основном» и 10 шт. в «Браке»: брак к сборке не разрешён.
	for _, s := range []struct{ iw, qty string }{{iwh, "3"}, {defect, "10"}} {
		if _, err := pool.Exec(ctx, `INSERT INTO stock (cell_id,good_id,batch_id,qty,internal_warehouse_id) VALUES ($1,$2,$3,$4,$5)`,
			cell, good, batch, s.qty, s.iw); err != nil {
			t.Fatalf("остаток: %v", err)
		}
	}

	svc := NewPickingLoadService(NewPickingRegistryService(repository.NewGoodsRepository(pool)),
		repository.NewPickingRepository(pool), repository.NewWarehouseRepository(pool))
	first := registryFile(t, [][5]string{
		{"Н1", "З1", "Клиент 1", "00-00000001", "2"},
		{"Н1", "З1", "Клиент 1", "00-00000999", "1"},
		{"Н1", "З2", "Клиент 1", "00-00000001", "2"},
	})

	pre, err := svc.Preview(ctx, "SHB", bytes.NewReader(first))
	if err != nil {
		t.Fatalf("Preview: %v", err)
	}
	if pre.Counts.New != 2 || len(pre.UnknownCodes) != 1 || !pre.Orders[0].HasUnknown ||
		!pre.Orders[0].HasShortage || *pre.Orders[0].Lines[0].Available != 3 || pre.Orders[0].Lines[1].Known {
		t.Errorf("предпросмотр: %+v", pre)
	}
	if n := count(`SELECT count(*) FROM picking_orders`) + count(`SELECT count(*) FROM picking_loads`); n != 0 {
		t.Fatalf("предпросмотр записал %d строк", n)
	}

	res, err := svc.Load(ctx, "SHB", "Реестр.xlsx", user, bytes.NewReader(first))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if res.LoadID == "" || res.Counts.New != 2 || count(`SELECT count(*) FROM picking_order_lines`) != 3 ||
		count(`SELECT count(*) FROM picking_orders WHERE has_unknown`) != 1 {
		t.Fatalf("первая загрузка: %+v", res.Counts)
	}

	// З2 собран; новый реестр: З1 пропал, у З2 стало 3 шт.
	if _, err := pool.Exec(ctx, `UPDATE picking_orders SET status='picked', picked_by=$1, picked_at=now() WHERE order_number='З2'`, user); err != nil {
		t.Fatal(err)
	}
	second := registryFile(t, [][5]string{{"Н1", "З2", "Клиент 1", "00-00000001", "3"}})
	res, err = svc.Load(ctx, "SHB", "Реестр 2.xlsx", user, bytes.NewReader(second))
	if err != nil {
		t.Fatalf("вторая загрузка: %v", err)
	}
	if res.Counts.Changed != 1 || res.Counts.Deleted != 1 || !res.Orders[0].Reopen {
		t.Errorf("вторая загрузка: %+v", res.Counts)
	}
	var status, assignee string
	var planQty int
	if err := pool.QueryRow(ctx, `
		SELECT o.status, o.assignee_id::text, l.plan_qty FROM picking_orders o
		JOIN picking_order_lines l ON l.order_id = o.id WHERE o.order_number = 'З2'`).Scan(&status, &assignee, &planQty); err != nil {
		t.Fatal(err)
	}
	if status != model.PickingStatusInProgress || assignee != user || planQty != 3 {
		t.Errorf("дособор З2: %s, %s, %d", status, assignee, planQty)
	}
	if count(`SELECT count(*) FROM picking_orders WHERE order_number='З1' AND deleted_at IS NOT NULL`) != 1 ||
		count(`SELECT count(*) FROM picking_order_changes WHERE kind IN ('order_deleted','qty_changed') AND order_status IN ('new','picked')`) != 2 {
		t.Error("удаление З1 и правка З2 не записаны в историю")
	}

	res, err = svc.Load(ctx, "SHB", "Реестр 2.xlsx", user, bytes.NewReader(second))
	if err != nil || res.Counts.Unchanged != 1 || res.Counts.Deleted != 0 || res.Counts.Changed != 0 {
		t.Errorf("повтор того же файла: %+v (%v)", res, err)
	}
	if count(`SELECT count(*) FROM picking_order_changes`) != 2 || count(`SELECT count(*) FROM picking_loads`) != 3 {
		t.Error("повтор того же файла добавил правки")
	}

	if _, err := svc.Preview(ctx, "SHB", bytes.NewReader([]byte("не xlsx"))); !errors.Is(err, ErrRegistryFile) {
		t.Errorf("испорченный файл: %v", err)
	}
}
