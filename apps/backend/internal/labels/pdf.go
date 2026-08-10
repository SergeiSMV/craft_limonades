// Package labels — генерация PDF-этикеток ячеек склада (P-FS-05).
// Раскладка по согласованному образцу: A4, 1 колонка × 8 этикеток на лист; на этикетке
// штрихкод Code128(адрес) + крупный адрес; для напольных ячеек — стрелка вниз.
package labels

import (
	"bytes"
	"fmt"
	"image/png"

	"github.com/boombuler/barcode"
	"github.com/boombuler/barcode/code128"
	"github.com/go-pdf/fpdf"

	"craftwms/internal/model"
)

// Параметры раскладки (мм). A4 портрет; 8 полос во всю ширину, режутся по пунктиру.
const (
	pageW      = 210.0
	pageH      = 297.0
	perPage    = 8
	labelH     = pageH / perPage // высота одной этикетки-полосы
	barcodeX   = 8.0
	barcodeW   = 55.0
	barcodeH   = 20.0
	addressX   = 68.0
	addressW   = 100.0
	arrowX     = 178.0 // центр стрелки (правее адреса)
	addrFontPt = 30.0
)

// Render строит PDF-этикеток по списку ячеек (уже отсортированному сервисом). Пустой список →
// валидный PDF без страниц (0 этикеток). Адрес — латиница/цифры, поэтому core-шрифт Helvetica.
func Render(cells []model.CellLabel) ([]byte, error) {
	pdf := fpdf.New("P", "mm", "A4", "")
	pdf.SetMargins(0, 0, 0)
	pdf.SetAutoPageBreak(false, 0)

	for i, c := range cells {
		if i%perPage == 0 {
			pdf.AddPage()
		}
		y := float64(i%perPage) * labelH

		// Штрихкод Code128(адрес) → PNG → изображение в PDF.
		img, err := barcodePNG(c.Address)
		if err != nil {
			return nil, err
		}
		name := "bc-" + c.Address // адрес уникален в пределах склада → уникальное имя ресурса
		pdf.RegisterImageOptionsReader(name, fpdf.ImageOptions{ImageType: "png"}, bytes.NewReader(img))
		pdf.ImageOptions(name, barcodeX, y+(labelH-barcodeH)/2, barcodeW, barcodeH, false,
			fpdf.ImageOptions{ImageType: "png"}, 0, "")

		// Крупный адрес, вертикально по центру полосы.
		pdf.SetFont("Helvetica", "B", addrFontPt)
		pdf.SetXY(addressX, y)
		pdf.CellFormat(addressW, labelH, c.Address, "", 0, "LM", false, 0, "")

		// Напольная ячейка → стрелка вниз (вектором, без завязки на глиф шрифта).
		if c.IsFloor {
			drawDownArrow(pdf, arrowX, y+labelH/2)
		}

		// Пунктирная линия реза по нижней границе этикетки.
		pdf.SetDashPattern([]float64{1.2, 1.2}, 0)
		pdf.SetLineWidth(0.2)
		pdf.Line(0, y+labelH, pageW, y+labelH)
		pdf.SetDashPattern([]float64{}, 0)
	}

	var buf bytes.Buffer
	if err := pdf.Output(&buf); err != nil {
		return nil, fmt.Errorf("вывод PDF: %w", err)
	}
	return buf.Bytes(), nil
}

// barcodePNG кодирует адрес в Code128 и возвращает PNG-байты (масштабированные под ширину этикетки).
func barcodePNG(address string) ([]byte, error) {
	bc, err := code128.Encode(address)
	if err != nil {
		return nil, fmt.Errorf("code128 %q: %w", address, err)
	}
	// Масштаб в пиксели: широкий и невысокий штрихкод, читается со среднего/близкого расстояния.
	scaled, err := barcode.Scale(bc, 600, 200)
	if err != nil {
		return nil, fmt.Errorf("scale barcode %q: %w", address, err)
	}
	var buf bytes.Buffer
	if err := png.Encode(&buf, scaled); err != nil {
		return nil, fmt.Errorf("png encode %q: %w", address, err)
	}
	return buf.Bytes(), nil
}

// drawDownArrow рисует чёрную стрелку вниз с центром в (cx, cy): прямоугольный стержень + треугольник.
func drawDownArrow(pdf *fpdf.Fpdf, cx, cy float64) {
	pdf.SetFillColor(0, 0, 0)
	pdf.Rect(cx-1.5, cy-9, 3, 11, "F") // стержень
	pdf.Polygon([]fpdf.PointType{      // наконечник вниз
		{X: cx - 5, Y: cy + 1},
		{X: cx + 5, Y: cy + 1},
		{X: cx, Y: cy + 9},
	}, "F")
}
