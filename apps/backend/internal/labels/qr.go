package labels

import (
	"fmt"

	"github.com/boombuler/barcode/qr"
	"github.com/go-pdf/fpdf"
)

// QR на этикетке напольной ячейки (ADHOC-61).
//
// Зачем: ячейку на ТСД сканируют по коду адреса, а адрес пола у стеллажа - кириллицей
// («D-Н-П»), которую Code128 набором B не кодирует. QR несёт адрес в UTF-8; ТСД узнаёт ячейку
// по содержимому кода, а не по символике. Сторона квадрата - высота штрих-кода профиля, защитная
// зона - та же, что у Code128 (не меньше 4 модулей QR при любом адресе пола).

// qrMatrix - тёмные модули QR адреса: n × n, dark[y][x].
func qrMatrix(value string) ([][]bool, error) {
	code, err := qr.Encode(value, qr.M, qr.Unicode)
	if err != nil {
		return nil, fmt.Errorf("QR %s: %w", value, err)
	}
	b := code.Bounds()
	n := b.Dx()
	dark := make([][]bool, n)
	for y := 0; y < n; y++ {
		dark[y] = make([]bool, n)
		for x := 0; x < n; x++ {
			r, _, _, _ := code.At(b.Min.X+x, b.Min.Y+y).RGBA()
			dark[y][x] = r < 0x8000
		}
	}
	return dark, nil
}

// qrWidth - полная ширина QR с защитными зонами, мм.
func qrWidth(p beamProfile) float64 {
	return p.bcH + 2*p.quiet
}

// drawQR - QR вектором: тёмные модули - залитые квадраты; (x, y) - левый верхний угол без защитной
// зоны, side - сторона квадрата.
func drawQR(pdf *fpdf.Fpdf, value string, x, y, side float64) error {
	dark, err := qrMatrix(value)
	if err != nil {
		return err
	}
	m := side / float64(len(dark))
	for row, line := range dark {
		for col, on := range line {
			if on {
				pdf.Rect(x+float64(col)*m, y+float64(row)*m, m, m, "F")
			}
		}
	}
	return nil
}
