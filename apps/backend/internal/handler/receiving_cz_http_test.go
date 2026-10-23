package handler_test

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/google/uuid"

	"craftwms/internal/service"
)

// Сценарные тесты приёмки с марками ЧЗ (CZ-05): тот же путь через настоящий роутер, что у
// приёмки без марок. Итог проверяется в базе — там, где его прочтут скан марки, «Проблемы
// склада» и задание на размещение: место каждой марки, короб ЧЗ как ГЕ, расхождения в «Изоляторе».

// Пиво с GTIN марок эталона: GTIN-14 04612728200172 — ШК 4612728200172 без ведущего нуля.
const (
	czBeerBarcode = "4612728200172"
	czBoxCode     = "00146127282000000173"
)

// czMark — КИ марки пива эталона с серийным номером n.
func czMark(n string) string { return "0104612728200172215" + n }

// seedCZGood заводит товар с ШК марок эталона (id — заданный или новый).
func seedCZGood(t *testing.T, e *rcvEnv, id string) string {
	t.Helper()
	if id == "" {
		id = uuid.NewString()
	}
	ctx := context.Background()
	if _, err := e.pool.Exec(ctx,
		`INSERT INTO goods (id,code,name,uom) VALUES ($1::uuid,'20031','Пиво светлое','шт')`, id); err != nil {
		t.Fatalf("товар: %v", err)
	}
	if _, err := e.pool.Exec(ctx,
		`INSERT INTO barcodes (good_id,barcode,symbology) VALUES ($1::uuid,$2,'ean13')`, id, czBeerBarcode); err != nil {
		t.Fatalf("ШК товара: %v", err)
	}
	return id
}

// scalar читает одно значение запросом к базе.
func (e *rcvEnv) scalar(t *testing.T, sql string, args ...any) string {
	t.Helper()
	var out string
	if err := e.pool.QueryRow(context.Background(), sql, args...).Scan(&out); err != nil {
		t.Fatalf("%s: %v", sql, err)
	}
	return out
}

// byWarehouse — остаток ячейки по внутренним складам, «КОД:кол-во» через пробел.
func (e *rcvEnv) byWarehouse(t *testing.T, cell string) string {
	t.Helper()
	return e.scalar(t, `
		SELECT COALESCE(string_agg(w.code || ':' || s.qty::text, ' ' ORDER BY w.code), '')
		FROM stock s JOIN internal_warehouses w ON w.id = s.internal_warehouse_id
		WHERE s.cell_id = $1::uuid AND s.qty > 0`, cell)
}

// marksPlaces — место каждой марки: «КИ@ГЕ» в коробе или «КИ@ячейка/склад», с «!» у марок
// проблемы; через пробел по КИ.
func (e *rcvEnv) marksPlaces(t *testing.T) string {
	t.Helper()
	return e.scalar(t, `
		SELECT string_agg(right(m.cis, 4) || '@' ||
		       CASE WHEN m.load_unit_id IS NOT NULL THEN 'LU' ELSE c.address || '/' || w.code END ||
		       CASE WHEN m.problem_id IS NULL THEN '' ELSE '!' END, ' ' ORDER BY m.cis)
		FROM cz_marks m
		LEFT JOIN cells c ON c.id = m.cell_id
		LEFT JOIN internal_warehouses w ON w.id = m.internal_warehouse_id
		`)
}

// Эталон приёмки с марками — вторая половина контракта (первая — Dart-тест приёмки): короб ЧЗ
// с групповой упаковкой в своей ячейке и марки россыпью в ячейке приёмки, одна — чужая.
func TestReceivingCZHTTP_clientWireFormat(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("testdata", "receipt_submit_cz.json"))
	if err != nil {
		t.Fatalf("эталон не читается: %v", err)
	}
	const (
		warehouse = "4e000000-0000-4000-8000-0000000000a1"
		supplier  = "4e000000-0000-4000-8000-0000000000b1"
		cell1     = "4e000000-0000-4000-8000-0000000000a3"
		good      = "4e000000-0000-4000-8000-0000000000c1"
		box       = "4e000000-0000-4000-8000-000000000002"
	)
	e := newReceivingE2E(t, map[string]string{"warehouse": warehouse, "supplier": supplier, "cell1": cell1})
	seedCZGood(t, e, good)

	if got := e.operations(t, string(raw)); len(got) != 1 || got[0] != service.StatusAccepted {
		t.Fatalf("эталонная приёмка не применилась: %v.\n"+
			"Формат разошёлся — сверьте testdata/receipt_submit_cz.json с тем, что шлёт клиент.", got)
	}

	// Короб ЧЗ — это ГЕ приёмки, упаковка — в нём.
	if got := e.scalar(t, `
		SELECT string_agg(kind || ':' || COALESCE(load_unit_id::text, parent_code), ' ' ORDER BY kind)
		FROM cz_aggregates`); got != "BOX:"+box+" GROUP:00146127282000000172" {
		t.Fatalf("агрегаты: %s", got)
	}
	// Марки короба — в ГЕ, россыпь — в ячейке приёмки; чужая — в «Изоляторе» с проблемой.
	if got := e.marksPlaces(t); got != "0001@LU 0002@LU 0003@LU 0004@С-Н-П/MAIN 0005@С-Н-П/ISOLATOR!" {
		t.Fatalf("места марок: %s", got)
	}
	if got := e.scalar(t, `SELECT cz_marked::text FROM goods WHERE id = $1::uuid`, good); got != "true" {
		t.Fatalf("товар с принятой маркой не помечен маркируемым")
	}
	if got := e.scalar(t, `
		SELECT reason || ' ' || status || ' ' || qty::text || ' ' || COALESCE(mark, '')
		FROM warehouse_problems`); got != "foreign_mark open 1.000 "+czMark("Mark0005") {
		t.Fatalf("проблема: %s", got)
	}
	if got := e.byWarehouse(t, e.cellDefault); got != "ISOLATOR:1.000 MAIN:1.000" {
		t.Fatalf("остаток ячейки приёмки: %s", got)
	}
	// Задание на размещение — только «Основной» россыпи: изолированное разместить нельзя.
	if got := e.scalar(t, `SELECT string_agg(qty::text, ' ') FROM putaway_task_items`); got != "1.000" {
		t.Fatalf("позиции задания: %s", got)
	}
}

// Короб ЧЗ с выбывшей маркой уходит в «Изолятор» целиком — ГЕ со всеми марками. Брак — лишь
// метка: короб остаётся в задании на размещение и переезжает как любой другой.
func TestReceivingCZHTTP_boxWithRetiredMark(t *testing.T) {
	e := newReceivingE2E(t, nil)
	good := seedCZGood(t, e, "")
	box := uuid.NewString()

	got := e.operations(t, jsonf(`{"operations":[{"operation_id":%q,"kind":"receipt_submit","payload":{
		"receipt_id":%q,"warehouse_id":%q,"doc_number":"ТН-1","doc_date":"01-10-2026",
		"load_units":[{"id":%q,"kind":"box","cz_code":%q}],
		"lines":[{"good_id":%q,"production_date":"01-09-2026","qty":2,"load_unit_id":%q,"marks":[
			{"cis":%q,"aggregate_code":%q},
			{"cis":%q,"aggregate_code":%q,"discrepancy":"retired"}]}]}}]}`,
		uuid.NewString(), uuid.NewString(), e.warehouse, box, czBoxCode,
		good, box, czMark("A001"), czBoxCode, czMark("A002"), czBoxCode))
	if strings.Join(got, ",") != service.StatusAccepted {
		t.Fatalf("приёмка: %v", got)
	}
	if got := e.scalar(t, `
		SELECT reason || ' ' || load_unit_id::text || ' ' || mark FROM warehouse_problems`); got != "retired "+box+" "+czBoxCode {
		t.Fatalf("проблема короба: %s", got)
	}
	if got := e.scalar(t, `
		SELECT w.code FROM load_units lu JOIN internal_warehouses w ON w.id = lu.internal_warehouse_id
		WHERE lu.id = $1::uuid`, box); got != "ISOLATOR" {
		t.Fatalf("склад короба: %s", got)
	}
	if got := e.marksPlaces(t); got != "A001@LU! A002@LU!" {
		t.Fatalf("марки короба: %s", got)
	}
	if got := e.byWarehouse(t, e.cellDefault); got != "ISOLATOR:2.000" {
		t.Fatalf("остаток ячейки приёмки: %s", got)
	}
	if got := e.scalar(t, `SELECT count(*)::text FROM putaway_task_items WHERE load_unit_id = $1::uuid`, box); got != "1" {
		t.Fatalf("короб в задании: %s", got)
	}
}

// Вся россыпь приёмки ушла в «Изолятор» — задания на размещение нет: размещать нечего.
func TestReceivingCZHTTP_isolatedLooseLeavesNoTask(t *testing.T) {
	e := newReceivingE2E(t, nil)
	good := seedCZGood(t, e, "")

	got := e.operations(t, jsonf(`{"operations":[{"operation_id":%q,"kind":"receipt_submit","payload":{
		"receipt_id":%q,"warehouse_id":%q,"doc_number":"ТН-1","doc_date":"01-10-2026",
		"lines":[{"good_id":%q,"production_date":"01-09-2026","qty":1,"marks":[
			{"cis":%q,"discrepancy":"foreign_mark"}]}]}}]}`,
		uuid.NewString(), uuid.NewString(), e.warehouse, good, czMark("B1")))
	if strings.Join(got, ",") != service.StatusAccepted {
		t.Fatalf("приёмка: %v", got)
	}
	if got := e.scalar(t, `SELECT count(*)::text FROM warehouse_tasks`); got != "0" {
		t.Fatalf("заданий: %s", got)
	}
	if got := e.byWarehouse(t, e.cellDefault); got != "ISOLATOR:1.000" {
		t.Fatalf("остаток ячейки приёмки: %s", got)
	}
}

// Ошибки ЧЗ — отказ, а не повтор: иначе очередь ТСД встала бы на такой приёмке навсегда.
func TestReceivingCZHTTP_rejections(t *testing.T) {
	e := newReceivingE2E(t, nil)
	good := seedCZGood(t, e, "")
	other := seedGood(t, e.pool, "Квас")
	receipt := func(goodID string, qty int, marks ...string) string {
		var list []string
		for _, m := range marks {
			list = append(list, jsonf(`{"cis":%q}`, m))
		}
		return jsonf(`{"operation_id":%q,"kind":"receipt_submit","payload":{
			"receipt_id":%q,"warehouse_id":%q,"doc_number":"ТН-1","doc_date":"01-10-2026",
			"lines":[{"good_id":%q,"production_date":"01-09-2026","qty":%d,"marks":[%s]}]}}`,
			uuid.NewString(), uuid.NewString(), e.warehouse, goodID, qty, strings.Join(list, ","))
	}

	got := e.operations(t, `{"operations":[`+strings.Join([]string{
		receipt(good, 1, czMark("C1")),               // принята
		receipt(good, 1, czMark("C1")),               // та же марка второй раз
		receipt(other, 1, czMark("C2")),              // GTIN марки — ШК другого товара
		receipt(good, 1, czMark("C3"), czMark("C4")), // марок больше количества
	}, ",")+`]}`)
	if want := "accepted,rejected,rejected,rejected"; strings.Join(got, ",") != want {
		t.Fatalf("статусы: %v, ожидалось %s", got, want)
	}
	if got := e.scalar(t, `SELECT count(*)::text FROM cz_marks`); got != "1" {
		t.Fatalf("марок принято: %s", got)
	}
}
