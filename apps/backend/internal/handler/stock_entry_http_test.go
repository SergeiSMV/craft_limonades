package handler_test

import (
	"context"
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Сценарные тесты ввода остатков с коробами и марками ЧЗ (ADHOC-46): старт → checkpoint
// ячейки → финал через настоящий роутер, итог - в базе.

// Эталон checkpoint - вторая половина контракта (первая - Dart-тест ввода остатков): россыпь и
// свой короб одного товара, короб ЧЗ с упаковкой и марки россыпью, одна чужая.
func TestStockEntryHTTP_clientWireFormat(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("testdata", "stock_entry_checkpoint.json"))
	if err != nil {
		t.Fatalf("эталон не читается: %v", err)
	}
	const (
		cell1  = "4e000000-0000-4000-8000-0000000000a3"
		beer   = "4e000000-0000-4000-8000-0000000000c1"
		lemon  = "4e000000-0000-4000-8000-0000000000c2"
		ownBox = "4e000000-0000-4000-8000-000000000011"
		czLU   = "4e000000-0000-4000-8000-000000000012"
	)
	e := newReceivingE2E(t, map[string]string{"cell1": cell1})
	seedCZGood(t, e, beer)
	if _, err := e.pool.Exec(context.Background(),
		`INSERT INTO goods (id,code,name,uom) VALUES ($1::uuid,'10001','Лимонад','шт')`, lemon); err != nil {
		t.Fatalf("товар: %v", err)
	}
	session := e.startEntry(t)

	if code, body := e.call(t, http.MethodPost, "/api/v1/stock-entry/sessions/"+session+"/cells",
		e.workerToken, string(raw)); code != http.StatusOK {
		t.Fatalf("эталонный checkpoint: %d %s.\n"+
			"Формат разошёлся - сверьте testdata/stock_entry_checkpoint.json с тем, что шлёт клиент.", code, body)
	}
	if code, body := e.call(t, http.MethodPost, "/api/v1/stock-entry/sessions/"+session+"/finalize",
		e.workerToken, ""); code != http.StatusOK {
		t.Fatalf("финал: %d %s", code, body)
	}

	// Лимонад: россыпь 4 + свой короб 6 - одна грань; пиво: короб ЧЗ 3, россыпь 1 и чужая марка
	// в «Изоляторе».
	if got := e.scalar(t, `
		SELECT string_agg(g.code || '/' || b.production_date::text || '/' || w.code || ':' || s.qty::int::text,
		                  ' ' ORDER BY g.code, b.production_date, w.code)
		FROM stock s
		JOIN goods g ON g.id = s.good_id
		JOIN batches b ON b.id = s.batch_id
		JOIN internal_warehouses w ON w.id = s.internal_warehouse_id
		WHERE s.cell_id = $1::uuid AND s.qty > 0`, cell1); got !=
		"10001/2026-08-15/MAIN:10 20031/2026-09-01/MAIN:3 20031/2026-09-02/ISOLATOR:1 20031/2026-09-02/MAIN:1" {
		t.Fatalf("остаток ячейки: %s", got)
	}
	if got := e.scalar(t, `
		SELECT l.cell_id::text || ' ' || c.qty::int::text FROM load_units l
		JOIN lu_content c ON c.load_unit_id = l.id WHERE l.id = $1::uuid`, ownBox); got != cell1+" 6" {
		t.Fatalf("свой короб: %s", got)
	}
	// Короб ЧЗ - ГЕ с марками, марки россыпью - в ячейке, чужая - в «Изоляторе».
	if got := e.scalar(t, `SELECT load_unit_id::text FROM cz_aggregates WHERE code = '00146127282000000172'`); got != czLU {
		t.Fatalf("короб ЧЗ: %s", got)
	}
	if got := e.marksPlaces(t); got != "0001@LU 0002@LU 0003@LU 0004@M1-1-1-1/MAIN 0005@M1-1-1-1/ISOLATOR!" {
		t.Fatalf("места марок: %s", got)
	}
	if got := e.scalar(t, `SELECT string_agg(DISTINCT source, ' ') FROM placements`); got != "stock_entry" {
		t.Fatalf("источник размещения: %s", got)
	}
}

// Короб, который уже есть на складе, - 422 со списком плохих строк по-русски; ТСД показывает
// текст как есть.
func TestStockEntryHTTP_lineRejection(t *testing.T) {
	e := newReceivingE2E(t, nil)
	lemon := e.scalar(t, `INSERT INTO goods (code,name,uom) VALUES ('10001','Лимонад','шт') RETURNING id::text`)
	box := e.scalar(t, `INSERT INTO load_units (id,kind) VALUES (gen_random_uuid(),'box') RETURNING id::text`)
	session := e.startEntry(t)

	code, body := e.call(t, http.MethodPost, "/api/v1/stock-entry/sessions/"+session+"/cells", e.workerToken,
		jsonf(`{"cell_id":%q,"load_units":[{"id":%q,"kind":"box"}],
		"lines":[{"good_id":%q,"production_date":"15-08-2026","qty":2,"load_unit_id":%q}]}`,
			e.cell1, box, lemon, box))
	if code != http.StatusUnprocessableEntity {
		t.Fatalf("код: %d %s", code, body)
	}
	var resp struct {
		Error string `json:"error"`
	}
	if err := json.Unmarshal(body, &resp); err != nil {
		t.Fatalf("тело: %v", err)
	}
	if !strings.Contains(resp.Error, "M1-1-1-1") || !strings.Contains(resp.Error, "короб уже есть в учёте склада") {
		t.Fatalf("текст отказа: %s", resp.Error)
	}
}

// startEntry открывает сессию ввода остатков на складе окружения.
func (e *rcvEnv) startEntry(t *testing.T) string {
	t.Helper()
	code, body := e.call(t, http.MethodPost, "/api/v1/stock-entry/sessions", e.workerToken,
		jsonf(`{"warehouse_id":%q}`, e.warehouse))
	if code != http.StatusCreated {
		t.Fatalf("старт сессии: %d %s", code, body)
	}
	var resp struct {
		SessionID string `json:"session_id"`
	}
	if err := json.Unmarshal(body, &resp); err != nil {
		t.Fatalf("тело старта: %v", err)
	}
	return resp.SessionID
}
