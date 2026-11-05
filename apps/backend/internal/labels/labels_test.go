package labels

import (
	"bytes"
	"errors"
	"fmt"
	"strings"
	"testing"
)

// Число модулей Code128 сверено с reportlab (rack_labels): 11 на символ + старт, контрольный и
// стоп (11 + 11 + 13).
func TestC128Modules(t *testing.T) {
	for value, want := range map[string]int{"B-4-1-8": 112, "B-1-2-12": 123, "C-10-3-12": 134} {
		got, err := c128Modules(value)
		if err != nil || got != want {
			t.Errorf("%s: %d %v, ждали %d", value, got, err, want)
		}
	}
	if _, err := c128Modules("Б-1"); err == nil {
		t.Error("кириллица в наборе B: ждали ошибку")
	}
}

// Штрихи идут слева направо и заканчиваются ровно на последнем модуле (стоп кончается штрихом).
func TestC128Bars(t *testing.T) {
	bars, err := c128Bars("B-1-2-12")
	if err != nil {
		t.Fatal(err)
	}
	end := 0
	for _, b := range bars {
		if b[0] < end || b[1] < 1 || b[1] > 4 {
			t.Fatalf("штрих %v после %d", b, end)
		}
		end = b[0] + b[1]
	}
	if n, _ := c128Modules("B-1-2-12"); end != n {
		t.Errorf("штрихи кончаются на %d, модулей %d", end, n)
	}
}

func pages(pdf []byte) int {
	return bytes.Count(pdf, []byte("/Type /Page\n"))
}

func TestBeamLabels(t *testing.T) {
	set := []Cell{
		{Address: "B-1-3-1"}, {Address: "B-1-1-1", IsFloor: true},
		{Address: "B-1-2-12", Barcode: true}, {Address: "B-1-1-12", Barcode: true, IsFloor: true},
	}
	pdf, err := BeamLabels(false, set, set)
	if err != nil || !bytes.HasPrefix(pdf, []byte("%PDF")) || pages(pdf) != 1 {
		t.Fatalf("большая балка: %v, страниц %d", err, pages(pdf))
	}
	items := append(append([]Cell{}, set...), set...)
	if pdf, err = BeamLabels(true, items, set); err != nil || pages(pdf) != 2 {
		t.Fatalf("малая балка, 8 этикеток по 6 на лист: %v, страниц %d", err, pages(pdf))
	}
	// Ячейка вне набора печатается по своему кеглю.
	if _, err = BeamLabels(false, []Cell{{Address: "Z-9-9-9", Barcode: true}}, set); err != nil {
		t.Errorf("ячейка вне набора: %v", err)
	}
	if _, err = BeamLabels(false, nil, set); !errors.Is(err, ErrNothingToPrint) {
		t.Errorf("пусто: %v", err)
	}
}

// Длинный адрес со штрих-кодом не влезает, нечитаемый символ — тоже причина; PDF не строится.
func TestBeamLabelsFitError(t *testing.T) {
	long := Cell{Address: strings.Repeat("B-12-", 8) + "1", Barcode: true}
	bad := Cell{Address: "Б-1-1-1", Barcode: true}
	_, err := BeamLabels(false, []Cell{long, bad}, []Cell{long, bad})
	var fe *FitError
	if !errors.As(err, &fe) || len(fe.Problems) < 2 {
		t.Fatalf("ждали FitError с двумя причинами: %v", err)
	}
}

func TestSideCards(t *testing.T) {
	var rows []CardRow
	for pos := 12; pos >= 10; pos-- {
		for tier := 3; tier >= 1; tier-- {
			rows = append(rows, CardRow{Address: fmt.Sprintf("B-1-%d-%d", tier, pos), Position: pos})
		}
	}
	cards := []Card{{Rack: "B-01", Rows: rows}, {Rack: "B-02", Rows: rows[:3]}, {Rack: "B-03", Rows: rows[:3]}}
	pdf, err := SideCards(cards, nil)
	if err != nil || pages(pdf) != 2 {
		t.Fatalf("три карточки по две на лист: %v, страниц %d", err, pages(pdf))
	}
	if _, err = SideCards(nil, nil); !errors.Is(err, ErrNothingToPrint) {
		t.Errorf("пусто: %v", err)
	}
	if _, err = SideCards([]Card{{Rack: "B-01", Rows: []CardRow{{Address: "Б-1"}}}}, nil); err == nil {
		t.Error("кириллица: ждали ошибку")
	}
	// Модуль считается по самому длинному адресу склада: с ним короткие адреса печатаются,
	// без него у кода B-1-1-1 модуль 0,321 мм и защитная зона 3 мм меньше 10 модулей.
	short := []Card{{Rack: "B-01", Rows: []CardRow{{Address: "B-1-1-1", Position: 1}}}}
	if _, err = SideCards(short, []string{"B-1-1-12"}); err != nil {
		t.Errorf("короткий адрес в складе с длинными: %v", err)
	}
	var fe *FitError
	if _, err = SideCards(short, nil); !errors.As(err, &fe) {
		t.Errorf("склад из коротких адресов: ждали FitError, %v", err)
	}
}

// Не влезающие строки уходят на продолжение карточки; каждая часть помещается в рабочее поле.
func TestSplitCard(t *testing.T) {
	var rows []CardRow
	for i := 0; i < 30; i++ {
		rows = append(rows, CardRow{Address: fmt.Sprintf("B-1-1-%d", i), Position: i / 5})
	}
	parts := splitCard(Card{Rack: "B-01", Rows: rows})
	total := 0
	for _, p := range parts {
		if p.Rack != "B-01" || cardUsed(p.Rows) > cardH-2*cardPad {
			t.Errorf("часть не влезает: %d строк, %.1f мм", len(p.Rows), cardUsed(p.Rows))
		}
		total += len(p.Rows)
	}
	if len(parts) < 3 || total != len(rows) {
		t.Errorf("частей %d, строк %d", len(parts), total)
	}
}
