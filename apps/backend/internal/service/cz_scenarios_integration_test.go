package service

import (
	"bytes"
	"encoding/json"
	"fmt"
	"reflect"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/shopspring/decimal"
	"github.com/xuri/excelize/v2"

	"craftwms/internal/repository"
)

// CZ-08D: сценарные тесты Честного знака по живой базе - путь марки от приёмки до УПД так, как
// его проходят склад и офис: приёмка короба ЧЗ одним сканом и россыпи марками (операция очереди
// receipt_submit, как с ТСД), размещение россыпи марками, перемещение бутылки из короба (вскрытие),
// сборка по реестру марками и коробом, «Завершить сборку», отгрузка, выгрузка Excel «Марки для
// УПД». Отдельные шаги покрыты тестами CZ-03…CZ-07; здесь - их стык.

// Вода с GTIN марок: GTIN-14 04612728200172 - ШК 4612728200172 без ведущего нуля. Короб ЧЗ - три
// марки: две в групповой упаковке, одна прямо в коробе.
const (
	czsBox   = "00146127282000000172"
	czsGroup = "0114612728200179215Grp0001"
)

// czsMark — КИ марки воды с номером n.
func czsMark(n int) string { return fmt.Sprintf("0104612728200172215Mark%04d", n) }

// czEnv — стенд сборки P9-09D плюс приёмка: ячейка приёмки, поставщик, маркируемая вода и
// очередь операций, как её собирает main.
type czEnv struct {
	*pickEnv
	ops       *OperationsService
	warehouse string
	receiving string // ячейка приёмки С-Н-П
	supplier  string
	water     string
	box       string // ГЕ короба ЧЗ
}

func newCZEnv(t *testing.T) *czEnv {
	t.Helper()
	e := &czEnv{pickEnv: newPickEnv(t), box: uuid.NewString()}
	e.ops = NewOperationsService(e.pickEnv.ops)
	e.warehouse = e.scan(`SELECT id::text FROM warehouses WHERE code = 'SHB'`)
	e.receiving = e.scan(`INSERT INTO cells (warehouse_id,address,is_default) VALUES ($1,'С-Н-П',true) RETURNING id::text`, e.warehouse)
	e.supplier = e.scan(`INSERT INTO suppliers (name) VALUES ('ООО «Родник»') RETURNING id::text`)
	e.water = e.scan(`INSERT INTO goods (code,name,uom) VALUES ('16149','Вода','шт') RETURNING id::text`)
	e.scan(`INSERT INTO barcodes (good_id,barcode,symbology) VALUES ($1,'4612728200172','ean13') RETURNING barcode`, e.water)
	return e
}

// apply отправляет операцию очереди от кладовщика Анны; отказ - провал теста.
func (e *czEnv) apply(kind string, payload any) {
	e.t.Helper()
	raw, err := json.Marshal(payload)
	if err != nil {
		e.t.Fatal(err)
	}
	res, err := e.ops.Apply(e.ctx, e.ann, []Operation{{OperationID: uuid.NewString(), Kind: kind, Payload: raw}})
	if err != nil {
		e.t.Fatalf("%s: %v", kind, err)
	}
	if res[0].Status != StatusAccepted {
		e.t.Fatalf("%s: %+v", kind, res[0])
	}
}

// receive — приёмка, как её шлёт ТСД: короб ЧЗ одним сканом в A-1 (упаковка с марками 1-2 и
// марка 3 прямо в коробе) и марки 4-5 россыпью в ячейку приёмки; партия 01.09.2026.
func (e *czEnv) receive() {
	e.t.Helper()
	mark := func(n int, agg string) map[string]string {
		return map[string]string{"cis": czsMark(n), "aggregate_code": agg, "discrepancy": ""}
	}
	e.apply(repository.KindReceiptSubmit, map[string]any{
		"receipt_id": uuid.NewString(), "warehouse_id": e.warehouse, "supplier_id": e.supplier,
		"doc_number": "ТН-1001", "doc_date": "01-10-2026",
		"load_units": []map[string]string{{"id": e.box, "kind": "box", "cz_code": czsBox}},
		"cz_groups":  []map[string]string{{"code": czsGroup, "parent_code": czsBox}},
		"lines": []map[string]any{
			{"good_id": e.water, "production_date": "01-09-2026", "qty": 3, "cell_id": e.cellA,
				"load_unit_id": e.box, "marks": []map[string]string{mark(1, czsGroup), mark(2, czsGroup), mark(3, czsBox)}},
			{"good_id": e.water, "production_date": "01-09-2026", "qty": 2,
				"marks": []map[string]string{mark(4, ""), mark(5, "")}},
		},
	})
}

// putAwayLoose размещает россыпь приёмки марками в B-1 по заданию на размещение.
func (e *czEnv) putAwayLoose() {
	e.t.Helper()
	task := e.scan(`SELECT id::text FROM warehouse_tasks WHERE kind = 'putaway'`)
	e.apply(repository.KindPutawaySubmit, map[string]any{
		"putaway_id": uuid.NewString(), "task_id": task, "warehouse_id": e.warehouse,
		"lines": []map[string]any{{"good_id": e.water, "production_date": "01-09-2026", "qty": 2,
			"to_cell_id": e.cellB, "marks": []string{czsMark(4), czsMark(5)}}},
	})
}

// places — место каждой марки: «N@LU» в коробе ЧЗ, «N@BOX» в коробе отгрузки, «N@ячейка»
// россыпью, «N:статус» не на складе; через пробел по номеру.
func (e *czEnv) places() string {
	e.t.Helper()
	return e.scan(`
		SELECT string_agg(right(m.cis, 1) ||
		       CASE WHEN m.status <> 'in_stock' THEN ':' || m.status
		            WHEN m.load_unit_id = $1::uuid THEN '@LU'
		            WHEN m.load_unit_id IS NOT NULL THEN '@BOX'
		            ELSE '@' || c.address END, ' ' ORDER BY m.cis)
		FROM cz_marks m LEFT JOIN cells c ON c.id = m.cell_id`, e.box)
}

// opened — вскрытые упаковки ЧЗ: «BOX», «GROUP» или оба через пробел.
func (e *czEnv) opened() string {
	e.t.Helper()
	return e.scan(`SELECT coalesce(string_agg(kind, ' ' ORDER BY kind), '') FROM cz_aggregates WHERE opened_at IS NOT NULL`)
}

// pickMarks — пик воды марками операцией очереди: из короба ЧЗ (lu) или россыпью из ячейки.
func (e *czEnv) pickMarks(order, box, cell, lu string, marks ...int) {
	e.t.Helper()
	cis := make([]string, len(marks))
	for i, n := range marks {
		cis[i] = czsMark(n)
	}
	line := e.scan(`SELECT id::text FROM picking_order_lines WHERE order_id = $1 AND good_id = $2`, order, e.water)
	in := map[string]any{"pick_id": uuid.NewString(), "order_id": order, "line_id": line, "box_id": box,
		"production_date": "01-09-2026", "qty": len(marks), "marks": cis}
	if lu != "" {
		in["source_load_unit_id"] = lu
	} else {
		in["source_cell_id"] = cell
	}
	e.apply(repository.KindPickingPick, in)
}

// upd — лист «Марки для УПД» выгрузки за дату реестра: строки «заказ код вид» без шапки.
func (e *czEnv) upd() []string {
	e.t.Helper()
	day, err := time.Parse(time.DateOnly, e.scan(`SELECT min(registry_date)::text FROM picking_orders`))
	if err != nil {
		e.t.Fatal(err)
	}
	data, _, err := e.portal.ExportXLSX(e.ctx, "SHB", day)
	if err != nil {
		e.t.Fatalf("выгрузка: %v", err)
	}
	f, err := excelize.OpenReader(bytes.NewReader(data))
	if err != nil {
		e.t.Fatal(err)
	}
	defer func() { _ = f.Close() }()
	rows, err := f.GetRows("Марки для УПД")
	if err != nil {
		e.t.Fatal(err)
	}
	var out []string
	for _, r := range rows[1:] {
		code := r[8]
		if len(code) > 4 && code[:2] == "01" && code != czsGroup {
			code = code[len(code)-1:] // марка - по номеру
		}
		out = append(out, r[2]+" "+r[7]+" "+code+" "+r[9])
	}
	return out
}

// TestCZScenario_wholeBoxShipped — короб ЧЗ уезжает целым, россыпь - марками.
//
// Приёмка: короб ЧЗ одним сканом в A-1, россыпь в ячейку приёмки, товар стал маркируемым.
// Размещение: россыпь марками в B-1, короб не тронут. Сборка: заказ 15601 - короб ЧЗ сканом
// (три марки из ГЕ), заказ 15602 - одна марка россыпи. Завершение и отгрузка не вскрывают короб,
// марки отгружены. В «Марках для УПД»: у 15601 строка «короб ЧЗ» с кодом агрегации и три марки
// «в коробе ЧЗ» под ней, у 15602 - марка.
func TestCZScenario_wholeBoxShipped(t *testing.T) {
	e := newCZEnv(t)
	e.receive()
	if got := e.places(); got != "1@LU 2@LU 3@LU 4@С-Н-П 5@С-Н-П" {
		t.Fatalf("после приёмки: %s", got)
	}
	if e.scan(`SELECT cz_marked::text FROM goods WHERE id = $1`, e.water) != "true" {
		t.Fatal("вода не стала маркируемой")
	}
	e.putAwayLoose()
	if got, op := e.places(), e.opened(); got != "1@LU 2@LU 3@LU 4@B-1 5@B-1" || op != "" {
		t.Fatalf("после размещения: %s, вскрыты %q", got, op)
	}

	e.registry([5]string{"20961", "15601", "Магазин", "00000016149", "3"},
		[5]string{"20962", "15602", "Кафе", "00000016149", "1"})
	whole, loose := e.order("15601"), e.order("15602")
	e.pickMarks(whole, e.start(whole, e.ann), "", e.box, 1, 2, 3)
	e.pickMarks(loose, e.start(loose, e.bob), e.cellB, "", 4)
	e.ship(whole, e.ann)
	e.ship(loose, e.bob)

	if got, op := e.places(), e.opened(); got != "1:shipped 2:shipped 3:shipped 4:shipped 5@B-1" || op != "" {
		t.Fatalf("после отгрузки: %s, вскрыты %q", got, op)
	}
	want := []string{
		"15601 01.09.2026 " + czsBox + " короб ЧЗ",
		"15601 01.09.2026 1 в коробе ЧЗ",
		"15601 01.09.2026 2 в коробе ЧЗ",
		"15601 01.09.2026 3 в коробе ЧЗ",
		"15602 01.09.2026 4 марка",
	}
	if got := e.upd(); !reflect.DeepEqual(got, want) {
		t.Fatalf("Марки для УПД:\n%q\nожидалось\n%q", got, want)
	}
}

// TestCZScenario_openedBox — вскрытый короб уезжает марками, целая упаковка в нём - своим кодом.
//
// Перемещение вынуло марку 3 из короба ЧЗ в B-1: короб вскрыт, групповая упаковка цела. Заказ
// 15601 собран упаковкой (марки 1-2) и маркой 3 из B-1 - в УПД упаковка своим кодом с марками,
// марка 3 отдельно, кода короба нет.
func TestCZScenario_openedBox(t *testing.T) {
	e := newCZEnv(t)
	e.receive()
	e.putAwayLoose()
	e.apply(repository.KindMovementSubmit, map[string]any{
		"movement_id": uuid.NewString(), "movement_kind": "move", "warehouse_id": e.warehouse,
		"lines": []map[string]any{{"good_id": e.water, "production_date": "01-09-2026", "qty": 1,
			"from_load_unit_id": e.box, "to_cell_id": e.cellB, "marks": []string{czsMark(3)}}},
	})
	if got, op := e.places(), e.opened(); got != "1@LU 2@LU 3@B-1 4@B-1 5@B-1" || op != "BOX" {
		t.Fatalf("после перемещения: %s, вскрыты %q", got, op)
	}

	e.registry([5]string{"20961", "15601", "Магазин", "00000016149", "3"})
	order := e.order("15601")
	box := e.start(order, e.ann)
	e.pickMarks(order, box, "", e.box, 1, 2)
	e.pickMarks(order, box, e.cellB, "", 3)
	e.ship(order, e.ann)

	if got, op := e.places(), e.opened(); got != "1:shipped 2:shipped 3:shipped 4@B-1 5@B-1" || op != "BOX" {
		t.Fatalf("после отгрузки: %s, вскрыты %q", got, op)
	}
	want := []string{
		"15601 01.09.2026 " + czsGroup + " упаковка ЧЗ",
		"15601 01.09.2026 1 в упаковке ЧЗ",
		"15601 01.09.2026 2 в упаковке ЧЗ",
		"15601 01.09.2026 3 марка",
	}
	if got := e.upd(); !reflect.DeepEqual(got, want) {
		t.Fatalf("Марки для УПД:\n%q\nожидалось\n%q", got, want)
	}
}

// TestCZScenario_partialBox — короб ЧЗ, взятый частично, вскрывается на «Завершить сборку».
//
// Заказ на 2: марки 1 (из упаковки) и 3 из короба ЧЗ. До завершения короб цел - марки ещё в
// ГЕ, «в сборке». После завершения короб и упаковка вскрыты, марка 2 осталась в коробе ЧЗ.
// «Марки для УПД» собранного (ещё не отгруженного) заказа - марками; отгрузка их не меняет.
func TestCZScenario_partialBox(t *testing.T) {
	e := newCZEnv(t)
	e.receive()
	e.registry([5]string{"20961", "15601", "Магазин", "00000016149", "2"})
	order := e.order("15601")
	box := e.start(order, e.ann)
	e.pickMarks(order, box, "", e.box, 1, 3)
	if got, op := e.places(), e.opened(); got != "1@LU 2@LU 3@LU 4@С-Н-П 5@С-Н-П" || op != "" {
		t.Fatalf("в сборке: %s, вскрыты %q", got, op)
	}
	if _, err := e.task.Complete(e.ctx, order, e.ann); err != nil {
		t.Fatalf("завершить: %v", err)
	}
	if got, op := e.places(), e.opened(); got != "1@BOX 2@LU 3@BOX 4@С-Н-П 5@С-Н-П" || op != "BOX GROUP" {
		t.Fatalf("после завершения: %s, вскрыты %q", got, op)
	}
	want := []string{"15601 01.09.2026 1 марка", "15601 01.09.2026 3 марка"}
	if got := e.upd(); !reflect.DeepEqual(got, want) {
		t.Fatalf("Марки для УПД собранного:\n%q\nожидалось\n%q", got, want)
	}
	if got := e.portalOrder(order).Order.FactQty; !got.Equal(decimal.NewFromInt(2)) {
		t.Fatalf("факт в портале: %s", got)
	}
}
