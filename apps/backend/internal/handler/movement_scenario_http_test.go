package handler_test

import (
	"context"
	"encoding/json"
	"net/http"
	"slices"
	"strings"
	"testing"

	"github.com/google/uuid"

	"craftwms/internal/service"
)

// Сценарные тесты перемещения (P6-08D): весь путь через настоящий роутер - так, как его
// проходят терминал кладовщика и портал оператора. Обе ветки - короб целиком и товар между
// коробами и россыпью. Итог каждого сценария проверяется там, где его увидят люди: остаток,
// состав коробов, снимок терминала, история на ТСД, документ «Движение» в портале и сам .xlsx.
// Пополнение заморожено (P6-06): на складе оно сейчас - то же перемещение товара.

// moveEnv - склад под перемещение: три ячейки хранения, приёмка положила в M1-1-1-1 два
// короба по 12 и россыпь 5 одной партии.
type moveEnv struct {
	*rcvEnv
	good         string
	cellB, cellC string
	box1, box2   string
}

func newMoveE2E(t *testing.T) *moveEnv {
	t.Helper()
	e := &moveEnv{rcvEnv: newReceivingE2E(t, nil), box1: uuid.NewString(), box2: uuid.NewString()}
	ctx := context.Background()
	seed := func(sql string, args ...any) string {
		var out string
		if err := e.pool.QueryRow(ctx, sql, args...).Scan(&out); err != nil {
			t.Fatalf("seed %q: %v", sql, err)
		}
		return out
	}
	e.good = seed(`INSERT INTO goods (code,name,uom) VALUES ('16121','Кальмар','шт') RETURNING id::text`)
	e.cellB = seed(`INSERT INTO cells (warehouse_id,address) VALUES ($1::uuid,'M1-1-1-2') RETURNING id::text`, e.warehouse)
	e.cellC = seed(`INSERT INTO cells (warehouse_id,address) VALUES ($1::uuid,'M1-1-1-3') RETURNING id::text`, e.warehouse)

	receipt := jsonf(`{"operations":[{"operation_id":%q,"kind":"receipt_submit","payload":{
		"receipt_id":%q,"warehouse_id":%q,"doc_number":"ТН-1","doc_date":"01-10-2026",
		"load_units":[{"id":%q,"kind":"box"},{"id":%q,"kind":"box"}],
		"lines":[
			{"good_id":%q,"production_date":"01-09-2026","qty":12,"load_unit_id":%q,"cell_id":%q},
			{"good_id":%q,"production_date":"01-09-2026","qty":12,"load_unit_id":%q,"cell_id":%q},
			{"good_id":%q,"production_date":"01-09-2026","qty":5,"cell_id":%q}]}}]}`,
		uuid.NewString(), uuid.NewString(), e.warehouse, e.box1, e.box2,
		e.good, e.box1, e.cell1, e.good, e.box2, e.cell1, e.good, e.cell1)
	if got := e.operations(t, receipt); len(got) != 1 || got[0] != service.StatusAccepted {
		t.Fatalf("приёмка под перемещение: %v", got)
	}
	return e
}

// move - батч одного сеанса перемещения: одна операция `movement_submit`.
func (e *moveEnv) move(operationID string, lines ...string) string {
	return jsonf(`{"operations":[{"operation_id":%q,"kind":"movement_submit","payload":{
		"movement_id":%q,"movement_kind":"move","warehouse_id":%q,"lines":[%s]}}]}`,
		operationID, uuid.NewString(), e.warehouse, strings.Join(lines, ","))
}

// boxLine - короб целиком в ячейку.
func boxMove(box, toCell string) string {
	return jsonf(`{"load_unit_id":%q,"to_cell_id":%q}`, box, toCell)
}

// goodsLine - товар партии 01-09-2026: откуда и куда - ячейка (россыпь) или короб; пустое -
// не задано. [iwh] - склад россыпи, пусто - «Основной».
func (e *moveEnv) goodsLine(qty int, fromCell, fromBox, toCell, toBox, iwh string) string {
	parts := []string{jsonf(`"good_id":%q,"production_date":"01-09-2026","qty":%d`, e.good, qty)}
	for _, kv := range [][2]string{
		{"from_cell_id", fromCell}, {"from_load_unit_id", fromBox},
		{"to_cell_id", toCell}, {"to_load_unit_id", toBox}, {"internal_warehouse_id", iwh},
	} {
		if kv[1] != "" {
			parts = append(parts, jsonf(`%q:%q`, kv[0], kv[1]))
		}
	}
	return "{" + strings.Join(parts, ",") + "}"
}

// stock - остаток товара по ячейкам M1-1-1-1 / M1-1-1-2 / M1-1-1-3.
func (e *moveEnv) stock(t *testing.T) string {
	t.Helper()
	return e.qtyIn(t, e.cell1, e.good) + " / " + e.qtyIn(t, e.cellB, e.good) + " / " + e.qtyIn(t, e.cellC, e.good)
}

// boxQty - сколько товара в коробе.
func (e *moveEnv) boxQty(t *testing.T, box string) string {
	t.Helper()
	var q string
	if err := e.pool.QueryRow(context.Background(),
		`SELECT COALESCE(sum(qty),0)::text FROM lu_content WHERE load_unit_id = $1::uuid`, box).Scan(&q); err != nil {
		t.Fatalf("состав короба: %v", err)
	}
	return q
}

// byWarehouse - остаток ячейки по кодам внутренних складов: «DEFECT:2.000 MAIN:15.000».
func (e *moveEnv) byWarehouse(t *testing.T, cell string) string {
	t.Helper()
	var s string
	if err := e.pool.QueryRow(context.Background(), `
		SELECT COALESCE(string_agg(w.code || ':' || s.qty::text, ' ' ORDER BY w.code), '')
		FROM stock s JOIN internal_warehouses w ON w.id = s.internal_warehouse_id
		WHERE s.cell_id = $1::uuid AND s.qty > 0`, cell).Scan(&s); err != nil {
		t.Fatalf("остаток по складам: %v", err)
	}
	return s
}

// iwh - id внутреннего склада по коду справочника.
func (e *moveEnv) iwh(t *testing.T, code string) string {
	t.Helper()
	var id string
	if err := e.pool.QueryRow(context.Background(),
		`SELECT id::text FROM internal_warehouses WHERE code = $1`, code).Scan(&id); err != nil {
		t.Fatalf("склад %s: %v", code, err)
	}
	return id
}

// terminal - снимок склада так, как его загрузит терминал: ячейка каждого короба и россыпь
// по ячейкам.
func (e *moveEnv) terminal(t *testing.T) (boxCells, loose map[string]string) {
	t.Helper()
	code, raw := e.call(t, http.MethodGet, "/api/v1/contents/snapshot", e.workerToken, "")
	var snap struct {
		LoadUnits []struct {
			ID     string `json:"id"`
			CellID string `json:"cell_id"`
		} `json:"load_units"`
		Loose []struct {
			CellID string `json:"cell_id"`
			Qty    string `json:"qty"`
		} `json:"loose"`
	}
	if code != http.StatusOK || json.Unmarshal(raw, &snap) != nil {
		t.Fatalf("снимок: %d %s", code, raw)
	}
	boxCells, loose = map[string]string{}, map[string]string{}
	for _, lu := range snap.LoadUnits {
		boxCells[lu.ID] = lu.CellID
	}
	for _, l := range snap.Loose {
		loose[l.CellID] = l.Qty
	}
	return boxCells, loose
}

// docRows - строки «Движения» как «откуда>куда:кол-во», по порядку: порядок строк в файле
// здесь не проверяется - его закрепляет эталон формата.
func docRows(rows [][]string) []string {
	out := make([]string, 0, len(rows))
	for _, r := range rows {
		out = append(out, r[0]+">"+r[1]+":"+r[5])
	}
	slices.Sort(out)
	return out
}

// Два сеанса, обе ветки. Первый: короб 1 целиком в M1-1-1-2, 4 шт из короба 2 россыпью
// туда же, 2 шт россыпи в M1-1-1-3. Второй: 3 шт россыпи M1-1-1-2 докладываются в короб 1,
// который там же лежит, - движение внутри ячейки, - и короб 2 целиком в M1-1-1-3. Товара
// на складе всё время 29; после каждого сеанса остаток, состав коробов, снимок терминала,
// история и «Движение» говорят одно и то же; движение внутри ячейки в «Движение» не идёт.
func TestMovementHTTP_twoSessionsBothBranches(t *testing.T) {
	e := newMoveE2E(t)

	if got := e.operations(t, e.move(uuid.NewString(),
		boxMove(e.box1, e.cellB),
		e.goodsLine(4, "", e.box2, e.cellB, "", ""),
		e.goodsLine(2, e.cell1, "", e.cellC, "", ""))); got[0] != service.StatusAccepted {
		t.Fatalf("сеанс 1: %v", got)
	}
	// M1-1-1-1: короб 2 (8) + россыпь 3; M1-1-1-2: короб 1 (12) + россыпь 4; M1-1-1-3: 2.
	if s := e.stock(t); s != "11.000 / 16.000 / 2.000" {
		t.Fatalf("остаток после сеанса 1: %s", s)
	}
	if b1, b2 := e.boxQty(t, e.box1), e.boxQty(t, e.box2); b1 != "12.000" || b2 != "8.000" {
		t.Errorf("короба после сеанса 1: %s и %s", b1, b2)
	}
	boxCells, loose := e.terminal(t)
	if boxCells[e.box1] != e.cellB || boxCells[e.box2] != e.cell1 ||
		loose[e.cell1] != "3" || loose[e.cellB] != "4" || loose[e.cellC] != "2" {
		t.Errorf("снимок после сеанса 1: короба %v, россыпь %v", boxCells, loose)
	}
	// В «Движении» коробов нет - только товар: короб (12) и 4 шт из короба 2 - одна партия по
	// одному маршруту M1-1-1-1 → M1-1-1-2, для 1С это одна строка на 16.
	docs := e.movementDocs(t)
	if len(docs) != 1 || docs[0]["operation"] != "move" || docs[0]["lines_count"] != float64(2) {
		t.Fatalf("«Движение» после сеанса 1: %v", docs)
	}
	_, rows := e.movementXLSX(t, docs[0]["id"].(string))
	if got := docRows(rows); !slices.Equal(got, []string{
		"M1-1-1-1>M1-1-1-2:16", "M1-1-1-1>M1-1-1-3:2",
	}) {
		t.Errorf("строки «Движения» сеанса 1: %v", got)
	}

	if got := e.operations(t, e.move(uuid.NewString(),
		e.goodsLine(3, e.cellB, "", "", e.box1, ""),
		boxMove(e.box2, e.cellC))); got[0] != service.StatusAccepted {
		t.Fatalf("сеанс 2: %v", got)
	}
	if s := e.stock(t); s != "3.000 / 16.000 / 10.000" {
		t.Fatalf("остаток после сеанса 2: %s", s)
	}
	if b1 := e.boxQty(t, e.box1); b1 != "15.000" {
		t.Errorf("короб 1 после докладки: %s", b1)
	}
	boxCells, loose = e.terminal(t)
	if boxCells[e.box2] != e.cellC || loose[e.cellB] != "1" || loose[e.cellC] != "2" {
		t.Errorf("снимок после сеанса 2: короба %v, россыпь %v", boxCells, loose)
	}
	docs = e.movementDocs(t)
	if len(docs) != 2 {
		t.Fatalf("документов «Движение» после двух сеансов: %d", len(docs))
	}
	second := docs[0]
	if second["lines_count"] == float64(2) {
		second = docs[1]
	}
	_, rows = e.movementXLSX(t, second["id"].(string))
	if got := docRows(rows); !slices.Equal(got, []string{"M1-1-1-1>M1-1-1-3:8"}) {
		t.Errorf("строки «Движения» сеанса 2 (докладка внутри ячейки не публикуется): %v", got)
	}
	// История на ТСД - оба сеанса, свежий первым; докладка внутри ячейки в ней видна.
	code, body := e.call(t, http.MethodGet, "/api/v1/movements", e.workerToken, "")
	var feed []map[string]any
	if code != http.StatusOK || json.Unmarshal(body, &feed) != nil || len(feed) != 2 ||
		feed[0]["load_units"] != float64(1) || feed[0]["goods"] != float64(1) {
		t.Fatalf("история перемещений: %d %s", code, body)
	}
}

// Отказы не оставляют следов. Сеанс проводится целиком или никак: законный перенос короба
// не уезжает вместе с отклонённой строкой. Отклоняются: больше, чем лежит в коробе; ячейка
// приёмки; брак в короб «Основного» склада. После всех отказов склад и портал как до них.
func TestMovementHTTP_rejectionsLeaveNoTrace(t *testing.T) {
	e := newMoveE2E(t)
	// Брак: 2 шт россыпи M1-1-1-1 помечены - чтобы было что положить не в тот короб.
	defect := e.iwh(t, "DEFECT")
	mark := jsonf(`{"operations":[{"operation_id":%q,"kind":"problem_submit","payload":{
		"problem_id":%q,"warehouse_id":%q,"good_id":%q,"production_date":"01-09-2026","qty":2,
		"cell_id":%q,"to_internal_warehouse_id":%q,"reason":"breakage"}}]}`,
		uuid.NewString(), uuid.NewString(), e.warehouse, e.good, e.cell1, defect)
	if got := e.operations(t, mark); got[0] != service.StatusAccepted {
		t.Fatalf("пометка брака: %v", got)
	}
	before, beforeSplit := e.stock(t), e.byWarehouse(t, e.cell1)

	cases := map[string]string{
		"короб и товара больше, чем в коробе": e.move(uuid.NewString(),
			boxMove(e.box1, e.cellB), e.goodsLine(20, "", e.box2, e.cellC, "", "")),
		"в ячейку приёмки": e.move(uuid.NewString(), boxMove(e.box1, e.cellDefault)),
		"из ячейки приёмки": e.move(uuid.NewString(),
			e.goodsLine(1, e.cellDefault, "", e.cellB, "", "")),
		"брак в короб «Основного»": e.move(uuid.NewString(),
			e.goodsLine(2, e.cell1, "", "", e.box1, defect)),
	}
	for name, batch := range cases {
		if got := e.operations(t, batch); got[0] != service.StatusRejected {
			t.Errorf("%s: %v, ожидался отказ", name, got)
		}
	}
	if s, split := e.stock(t), e.byWarehouse(t, e.cell1); s != before || split != beforeSplit {
		t.Fatalf("отказы сдвинули остаток: %s (%s), было %s (%s)", s, split, before, beforeSplit)
	}
	if b1, b2 := e.boxQty(t, e.box1), e.boxQty(t, e.box2); b1 != "12.000" || b2 != "12.000" {
		t.Errorf("короба после отказов: %s и %s", b1, b2)
	}
	var movements int
	if err := e.pool.QueryRow(context.Background(), `SELECT count(*) FROM movements`).Scan(&movements); err != nil || movements != 0 {
		t.Errorf("проведённых перемещений после отказов: %d (%v)", movements, err)
	}
	if docs := e.movementDocs(t); len(docs) != 0 {
		t.Errorf("отказы оставили «Движение»: %v", docs)
	}
}

// Обрыв ответа. Терминал отправил сеанс, ответ не дошёл - он шлёт тот же батч ещё раз.
// Повтор получает «уже принято»: короб не переезжает дважды, товар не уходит дважды,
// документ и запись истории - одни.
func TestMovementHTTP_replayAfterLostResponse(t *testing.T) {
	e := newMoveE2E(t)
	batch := e.move(uuid.NewString(),
		boxMove(e.box1, e.cellB), e.goodsLine(3, e.cell1, "", e.cellC, "", ""))
	if got := e.operations(t, batch); got[0] != service.StatusAccepted {
		t.Fatalf("сеанс: %v", got)
	}
	after := e.stock(t)
	if got := e.operations(t, batch); got[0] != service.StatusDuplicate {
		t.Fatalf("повтор: %v, ожидался duplicate", got)
	}
	if s := e.stock(t); s != after || s != "14.000 / 12.000 / 3.000" {
		t.Errorf("остаток после повтора: %s, после сеанса было %s", s, after)
	}
	if docs := e.movementDocs(t); len(docs) != 1 {
		t.Errorf("документов «Движение» после повтора: %d", len(docs))
	}
	code, body := e.call(t, http.MethodGet, "/api/v1/movements", e.workerToken, "")
	var feed []any
	if code != http.StatusOK || json.Unmarshal(body, &feed) != nil || len(feed) != 1 {
		t.Errorf("история после повтора: %d %s", code, body)
	}
}

// Помеченный товар едет своей меткой (P6-07-1). Короб 2 целиком в «Изоляторе», 2 шт
// россыпи - «Брак». Короб переезжает в M1-1-1-2 со своим складом, брак россыпью - в
// M1-1-1-3 строкой своего склада; «Основной» в M1-1-1-1 не задет.
func TestMovementHTTP_markedGoodsTravelWithMark(t *testing.T) {
	e := newMoveE2E(t)
	defect, isolator := e.iwh(t, "DEFECT"), e.iwh(t, "ISOLATOR")
	marks := jsonf(`{"operations":[
		{"operation_id":%q,"kind":"problem_submit","payload":{
			"problem_id":%q,"warehouse_id":%q,"load_unit_id":%q,
			"to_internal_warehouse_id":%q,"reason":"other","comment":"развакуум"}},
		{"operation_id":%q,"kind":"problem_submit","payload":{
			"problem_id":%q,"warehouse_id":%q,"good_id":%q,"production_date":"01-09-2026","qty":2,
			"cell_id":%q,"to_internal_warehouse_id":%q,"reason":"breakage"}}]}`,
		uuid.NewString(), uuid.NewString(), e.warehouse, e.box2, isolator,
		uuid.NewString(), uuid.NewString(), e.warehouse, e.good, e.cell1, defect)
	if got := e.operations(t, marks); len(got) != 2 || got[0] != service.StatusAccepted || got[1] != service.StatusAccepted {
		t.Fatalf("пометки: %v", got)
	}
	if s := e.byWarehouse(t, e.cell1); s != "DEFECT:2.000 ISOLATOR:12.000 MAIN:15.000" {
		t.Fatalf("до перемещения: %s", s)
	}

	if got := e.operations(t, e.move(uuid.NewString(),
		boxMove(e.box2, e.cellB),
		e.goodsLine(2, e.cell1, "", e.cellC, "", defect))); got[0] != service.StatusAccepted {
		t.Fatalf("перемещение помеченного: %v", got)
	}
	a, b, c := e.byWarehouse(t, e.cell1), e.byWarehouse(t, e.cellB), e.byWarehouse(t, e.cellC)
	if a != "MAIN:15.000" || b != "ISOLATOR:12.000" || c != "DEFECT:2.000" {
		t.Errorf("после перемещения: M1-1-1-1 %q, M1-1-1-2 %q, M1-1-1-3 %q", a, b, c)
	}
	docs := e.movementDocs(t)
	if len(docs) != 1 {
		t.Fatalf("«Движение»: %v", docs)
	}
	_, rows := e.movementXLSX(t, docs[0]["id"].(string))
	if got := docRows(rows); !slices.Equal(got, []string{"M1-1-1-1>M1-1-1-2:12", "M1-1-1-1>M1-1-1-3:2"}) {
		t.Errorf("строки «Движения»: %v", got)
	}
}

// ADHOC-40 (долг 26). Два терминала по устаревшему снимку: сеанс, в котором две строки уже
// неисполнимы, отклоняется одним ответом со списком обеих - по-русски и с товаром и местами,
// как их видит кладовщик. Терминал показывает этот текст на экране «Несинхронизированное».
func TestMovementHTTP_rejectionNamesAllBadLines(t *testing.T) {
	e := newMoveE2E(t)
	batch := e.move(uuid.NewString(),
		e.goodsLine(50, e.cell1, "", e.cellB, "", ""), // россыпи в M1-1-1-1 только 5
		boxMove(e.box1, e.cellB),                      // исполнима
		e.goodsLine(20, "", e.box2, e.cellC, "", ""),  // в коробе только 12
	)
	code, raw := e.call(t, http.MethodPost, "/api/v1/operations", e.workerToken, batch)
	if code != http.StatusOK {
		t.Fatalf("батч: код %d, %s", code, raw)
	}
	var body struct {
		Results []struct {
			Status string `json:"status"`
			Error  string `json:"error"`
		} `json:"results"`
	}
	if err := json.Unmarshal(raw, &body); err != nil || len(body.Results) != 1 {
		t.Fatalf("ответ батча: %s (%v)", raw, err)
	}
	res := body.Results[0]
	if res.Status != service.StatusRejected {
		t.Fatalf("статус %s, ожидался отказ", res.Status)
	}
	for _, want := range []string{
		"Отклонено строк: 2 из 3",
		"Кальмар · партия 01.09.2026 · 50 шт: M1-1-1-1 → M1-1-1-2: в источнике не хватает товара этой партии",
		"Кальмар · партия 01.09.2026 · 20 шт: короб ",
		"→ M1-1-1-3: в источнике не хватает товара этой партии",
	} {
		if !strings.Contains(res.Error, want) {
			t.Errorf("в отказе нет %q:\n%s", want, res.Error)
		}
	}
	if strings.Contains(res.Error, "→ M1-1-1-2: короб") || strings.Count(res.Error, "\n•") != 2 {
		t.Errorf("исполнимая строка попала в отказ:\n%s", res.Error)
	}
}
