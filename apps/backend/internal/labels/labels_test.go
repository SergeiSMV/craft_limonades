package labels

import (
	"bytes"
	"errors"
	"fmt"
	"math"
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
	// Код такого адреса шире этикетки — кеглем не спасти.
	long := Cell{Address: strings.Repeat("B-12-", 12) + "1", Barcode: true}
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
	// Склад из одних коротких адресов печатается: модуль кода B-1-1-1 был бы 0,321 мм, он
	// ограничен 0,3 мм — защитная зона 3 мм остаётся в 10 модулях.
	short := []Card{{Rack: "B-01", Rows: []CardRow{{Address: "B-1-1-1", Position: 1}}}}
	for _, set := range [][]string{{"B-1-1-12"}, nil} {
		if _, err = SideCards(short, set); err != nil {
			t.Errorf("короткий адрес, набор %v: %v", set, err)
		}
	}
	if m := cardModule(112); m != cardModuleMax {
		t.Errorf("модуль короткого кода: %v", m)
	}
	if m := cardModule(134); math.Abs(m-36.0/134) > 1e-12 {
		t.Errorf("модуль длинного кода как у скрипта: %v", m)
	}
}

// Не влезающий адрес не останавливает печать: кегль от capMin уменьшается на 1 пт, пока
// строка не влезет.
func TestFitSizeStepsDown(t *testing.T) {
	_, width := newPDF("t")
	addr := strings.Repeat("B-12-", 6) + "1"
	floor := largeBeam.capMin / capRatio / ptToMM
	avail := width(addr, floor) * 0.6
	size, ok := fitSize(addr, avail, largeBeam.capMax, largeBeam.capMin, width)
	if !ok || width(addr, size) > avail {
		t.Fatalf("ждали влезающий кегль: %v %v", size, ok)
	}
	if steps := floor - size; math.Abs(steps-math.Round(steps)) > 1e-9 || steps < 1 {
		t.Errorf("кегль %v не на шаг 1 пт от %v", size, floor)
	}
	if width(addr, size+1) <= avail {
		t.Errorf("кегль %v уменьшен лишний раз", size)
	}
	if _, ok := fitSize(addr, -1, largeBeam.capMax, largeBeam.capMin, width); ok {
		t.Error("отрицательное место: ждали ok=false")
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

// Напольная ячейка (ADHOC-61): адрес кириллицей печатается с QR и встроенным шрифтом, рядом с
// обычными этикетками того же листа; QR квадратный и не пустой.
func TestBeamLabelsFloorQR(t *testing.T) {
	set := []Cell{{Address: "D-Н-П", QR: true}, {Address: "С-Н-П", QR: true, IsFloor: true}, {Address: "B-1-1-12", Barcode: true}}
	for _, small := range []bool{false, true} {
		pdf, err := BeamLabels(small, set, set)
		if err != nil {
			t.Fatalf("small=%v: %v", small, err)
		}
		if !bytes.Contains(pdf, []byte(cyrFontName)) && !bytes.Contains(pdf, []byte(strings.ToLower(cyrFontName))) {
			t.Errorf("small=%v: в PDF нет шрифта кириллицы", small)
		}
	}
	dark, err := qrMatrix("D-Н-П")
	if err != nil {
		t.Fatal(err)
	}
	on := 0
	for _, row := range dark {
		if len(row) != len(dark) {
			t.Fatalf("QR не квадратный: %d × %d", len(row), len(dark))
		}
		for _, v := range row {
			if v {
				on++
			}
		}
	}
	if on == 0 {
		t.Error("QR пустой")
	}
	if needsCyrFont("B-1-1-12") || !needsCyrFont("D-Н-П") {
		t.Error("needsCyrFont: латиница — Helvetica, кириллица — встроенный шрифт")
	}
}
