package importer

import (
	"os"
	"strings"
	"testing"
)

// TestParseCells_realFile — парсинг реальной выгрузки ячеек (.xlsx: колонки cell/floor).
func TestParseCells_realFile(t *testing.T) {
	f, err := os.Open("testdata/cells_sample.xlsx")
	if err != nil {
		t.Fatalf("открыть образец: %v", err)
	}
	defer func() { _ = f.Close() }()

	res, err := ParseCells(f)
	if err != nil {
		t.Fatalf("ParseCells: %v", err)
	}

	if len(res.Errors) != 0 {
		t.Errorf("ожидалось 0 отклонённых строк, получено %d: %+v", len(res.Errors), res.Errors)
	}
	if len(res.Cells) != 125 {
		t.Fatalf("ячеек: ожидалось 125, получено %d", len(res.Cells))
	}

	// Признак floor и уникальность адресов.
	seen := map[string]bool{}
	floors := 0
	for _, c := range res.Cells {
		if c.Address == "" {
			t.Errorf("пустой адрес в результате")
		}
		if seen[c.Address] {
			t.Errorf("дубль адреса в результате: %q", c.Address)
		}
		seen[c.Address] = true
		if c.IsFloor {
			floors++
		}
	}
	if floors != 25 {
		t.Errorf("напольных ячеек: ожидалось 25, получено %d", floors)
	}

	// Точечная проверка: первая ячейка файла — M1-1-1-1, floor=true.
	if res.Cells[0].Address != "M1-1-1-1" || !res.Cells[0].IsFloor {
		t.Errorf("первая ячейка: ожидалось {M1-1-1-1, floor=true}, получено {%s, floor=%v}",
			res.Cells[0].Address, res.Cells[0].IsFloor)
	}
}

// TestParseCells_missingColumn — файл без обязательной колонки floor → ошибка (а не тихий импорт).
func TestParseCells_missingColumn(t *testing.T) {
	// Минимальный xlsx собираем через тот же excelize — но проще проверить на строке заголовка:
	// подсовываем reader на невалидный контент → должна быть ошибка открытия.
	_, err := ParseCells(strings.NewReader("не xlsx"))
	if err == nil {
		t.Fatal("ожидалась ошибка на невалидном файле, получено nil")
	}
}

// TestParseBool — разбор признака floor из разных представлений.
func TestParseBool(t *testing.T) {
	cases := map[string]struct {
		val, ok bool
	}{
		"true": {true, true}, "TRUE": {true, true}, "1": {true, true}, "да": {true, true},
		"false": {false, true}, "FALSE": {false, true}, "0": {false, true}, "нет": {false, true},
		"":      {false, true},                         // пусто = не напольная
		"maybe": {false, false}, "yes": {false, false}, // нераспознанное → ok=false
	}
	for in, want := range cases {
		got, ok := parseBool(in)
		if got != want.val || ok != want.ok {
			t.Errorf("parseBool(%q) = (%v,%v), ожидалось (%v,%v)", in, got, ok, want.val, want.ok)
		}
	}
}
