package handler_test

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/google/uuid"

	"craftwms/internal/service"
)

// Эталон формата движения (P6-03) — серверная половина контракта; клиентская появится вместе
// с потоком перемещения на ТСД (P6-04). Настоящий роутер применяет ровно это тело: короба
// лежат в ячейке хранения M1-1-1-3 (из ячейки приёмки терминал не перемещает — её разносят
// заданием); первый короб целиком переезжает в M1-1-1-2, товар из второго ложится россыпью
// в M1-1-1-1, и часть этой россыпи докладывается в переехавший короб.
//
// Пополнение (P6-05) — тот же формат с другим видом документа, поэтому тот же эталон
// прогоняется и пополнением: короб целиком и товар в любых сочетаниях проходят одинаково.
// Клиентская половина пополнения появится с выбором вида операции на ТСД (P6-06).
func TestMovementHTTP_clientWireFormat(t *testing.T) {
	fixture := string(readFixture(t, "movement_submit.json"))
	for _, kind := range []string{"move", "replenish"} {
		t.Run(kind, func(t *testing.T) {
			body := strings.Replace(fixture, `"movement_kind": "move"`, `"movement_kind": "`+kind+`"`, 1)
			if !strings.Contains(body, `"movement_kind": "`+kind+`"`) {
				t.Fatal("в эталоне не найден вид документа")
			}
			applyMovementFixture(t, []byte(body), kind)
		})
	}
}

// applyMovementFixture готовит склад под эталон движения, применяет тело raw настоящим
// роутером и сверяет остаток, состав коробов и вид проведённого документа.
func applyMovementFixture(t *testing.T, raw []byte, kind string) {
	t.Helper()
	var mf struct {
		Operations []struct {
			Payload struct {
				WarehouseID string `json:"warehouse_id"`
				Lines       []struct {
					LoadUnitID     string `json:"load_unit_id"`
					GoodID         string `json:"good_id"`
					FromCellID     string `json:"from_cell_id"`
					FromLoadUnitID string `json:"from_load_unit_id"`
					ToCellID       string `json:"to_cell_id"`
				} `json:"lines"`
			} `json:"payload"`
		} `json:"operations"`
	}
	if err := json.Unmarshal(raw, &mf); err != nil {
		t.Fatalf("эталон движения не разбирается: %v", err)
	}
	p := mf.Operations[0].Payload
	box1, cell2 := p.Lines[0].LoadUnitID, p.Lines[0].ToCellID
	good, box2, cell1 := p.Lines[1].GoodID, p.Lines[1].FromLoadUnitID, p.Lines[1].ToCellID
	if p.Lines[2].FromCellID != cell1 {
		t.Fatalf("третья строка эталона берёт россыпь не из M1-1-1-1: %s", p.Lines[2].FromCellID)
	}

	e := newReceivingE2E(t, map[string]string{"warehouse": p.WarehouseID, "cell1": cell1})
	ctx := context.Background()
	if _, err := e.pool.Exec(ctx, `INSERT INTO goods (id,code,name,uom) VALUES ($1::uuid,'16121','Кальмар','шт')`, good); err != nil {
		t.Fatalf("товар эталона: %v", err)
	}
	if _, err := e.pool.Exec(ctx, `INSERT INTO cells (id,warehouse_id,address) VALUES ($1::uuid,$2::uuid,'M1-1-1-2')`,
		cell2, e.warehouse); err != nil {
		t.Fatalf("ячейка эталона: %v", err)
	}
	var cell3 string
	if err := e.pool.QueryRow(ctx, `INSERT INTO cells (warehouse_id,address) VALUES ($1::uuid,'M1-1-1-3')
		RETURNING id::text`, e.warehouse).Scan(&cell3); err != nil {
		t.Fatalf("ячейка хранения коробов: %v", err)
	}

	// Приёмка кладёт сразу в ячейку хранения M1-1-1-3 два короба по 12 и россыпь 5 одной партии.
	receipt := jsonf(`{"operations":[{"operation_id":%q,"kind":"receipt_submit","payload":{
		"receipt_id":%q,"warehouse_id":%q,"doc_number":"ТН-1","doc_date":"01-10-2026",
		"load_units":[{"id":%q,"kind":"box"},{"id":%q,"kind":"box"}],
		"lines":[
			{"good_id":%q,"production_date":"01-09-2026","qty":12,"load_unit_id":%q,"cell_id":%q},
			{"good_id":%q,"production_date":"01-09-2026","qty":12,"load_unit_id":%q,"cell_id":%q},
			{"good_id":%q,"production_date":"01-09-2026","qty":5,"cell_id":%q}]}}]}`,
		uuid.NewString(), uuid.NewString(), p.WarehouseID, box1, box2,
		good, box1, cell3, good, box2, cell3, good, cell3)
	if got := e.operations(t, receipt); len(got) != 1 || got[0] != service.StatusAccepted {
		t.Fatalf("приёмка под эталон не применилась: %v", got)
	}

	if got := e.operations(t, string(raw)); len(got) != 1 || got[0] != service.StatusAccepted {
		t.Fatalf("эталонное движение не применилось: %v.\n"+
			"Формат разошёлся — сверьте testdata/movement_submit.json с тем, что шлёт клиент.", got)
	}

	// M1-1-1-3: 29 − короб 12 − 3 из второго короба = 14 (второй короб 9 + россыпь 5);
	// M1-1-1-1: 3 − 2 в короб = 1; M1-1-1-2: короб 12 + 2 = 14.
	if c3, c1, c2 := e.qtyIn(t, cell3, good), e.qtyIn(t, cell1, good), e.qtyIn(t, cell2, good); c3 != "14.000" || c1 != "1.000" || c2 != "14.000" {
		t.Fatalf("остаток после движения: M1-1-1-3=%s M1-1-1-1=%s M1-1-1-2=%s, ожидалось 14 / 1 / 14", c3, c1, c2)
	}
	var contents string
	if err := e.pool.QueryRow(ctx, `SELECT string_agg(qty::text, ' ' ORDER BY load_unit_id = $2::uuid DESC)
		FROM lu_content WHERE load_unit_id IN ($1::uuid, $2::uuid)`, box2, box1).Scan(&contents); err != nil || contents != "14.000 9.000" {
		t.Fatalf("состав коробов: %q (%v), ожидалось 14 (переехавший) и 9", contents, err)
	}
	var docKind string
	if err := e.pool.QueryRow(ctx, `SELECT kind FROM movements`).Scan(&docKind); err != nil || docKind != kind {
		t.Fatalf("вид документа: %q (%v), ожидалось %q", docKind, err, kind)
	}

	// Ячейка приёмки С-Н-П движению не источник: документ отклоняется сервером, даже если
	// терминал его прислал: инвариант задания на размещение держит сервер.
	fromReceiving := jsonf(`{"operations":[{"operation_id":%q,"kind":"movement_submit","payload":{
		"movement_id":%q,"movement_kind":%q,"warehouse_id":%q,
		"lines":[{"good_id":%q,"production_date":"01-09-2026","qty":1,"from_cell_id":%q,"to_cell_id":%q}]}}]}`,
		uuid.NewString(), uuid.NewString(), kind, p.WarehouseID, good, e.cellDefault, cell1)
	if got := e.operations(t, fromReceiving); len(got) != 1 || got[0] != service.StatusRejected {
		t.Fatalf("движение из ячейки приёмки: %v, ожидался отказ", got)
	}
}
