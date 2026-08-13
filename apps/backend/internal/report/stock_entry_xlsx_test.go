package report

import (
	"bytes"
	"testing"
	"time"

	"github.com/xuri/excelize/v2"

	"craftwms/internal/model"
)

// BuildStockEntryXLSX — чистая функция: проверяем валидность xlsx, заголовки, форматирование даты,
// числовое количество и пустой код.
func TestBuildStockEntryXLSX(t *testing.T) {
	code := "16121"
	rep := model.StockEntryReport{
		WarehouseCode: "SHB",
		WarehouseName: "Шабулина",
		CreatedAt:     time.Date(2026, 8, 14, 0, 0, 0, 0, time.UTC),
		Rows: []model.StockEntryReportRow{
			{CellAddress: "M1-1-1-1", GoodCode: &code, GoodName: "Кальмар", ProductionDate: "2026-01-15", Qty: "10.500"},
			{CellAddress: "M1-1-2-1", GoodCode: nil, GoodName: "Весовой", ProductionDate: "bad", Qty: "3"},
		},
	}

	data, err := BuildStockEntryXLSX(rep)
	if err != nil {
		t.Fatalf("BuildStockEntryXLSX: %v", err)
	}
	if !bytes.HasPrefix(data, []byte("PK")) { // .xlsx = zip-архив
		t.Fatalf("ожидался .xlsx (PK-заголовок)")
	}

	f, err := excelize.OpenReader(bytes.NewReader(data))
	if err != nil {
		t.Fatalf("open xlsx: %v", err)
	}
	defer func() { _ = f.Close() }()

	rows, err := f.GetRows(sheetName)
	if err != nil {
		t.Fatalf("GetRows: %v", err)
	}
	if len(rows) != 3 { // заголовок + 2 строки
		t.Fatalf("ожидалось 3 строки (заголовок + 2), получено %d", len(rows))
	}
	// Заголовок.
	for i, h := range headers {
		if rows[0][i] != h {
			t.Errorf("заголовок [%d]: ожидалось %q, получено %q", i, h, rows[0][i])
		}
	}
	// Первая строка: склад·ячейка·код·наим·дата(дд.мм.гггг)·кол-во(число).
	want := []string{"Шабулина", "M1-1-1-1", "16121", "Кальмар", "15.01.2026", "10.5"}
	for i, v := range want {
		if rows[1][i] != v {
			t.Errorf("строка 1 [%d]: ожидалось %q, получено %q", i, v, rows[1][i])
		}
	}
	// Вторая строка: пустой код, «плохая» дата — как есть, кол-во 3.
	if rows[2][2] != "" {
		t.Errorf("пустой код: получено %q", rows[2][2])
	}
	if rows[2][4] != "bad" {
		t.Errorf("нераспознанная дата должна остаться как есть: получено %q", rows[2][4])
	}
	if rows[2][5] != "3" {
		t.Errorf("кол-во: ожидалось 3, получено %q", rows[2][5])
	}
}
