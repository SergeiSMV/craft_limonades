package labels

import (
	_ "embed"

	"github.com/go-pdf/fpdf"
)

// Шрифт адресов с кириллицей (ADHOC-61): напольная ячейка «D-Н-П».
//
// Зачем: этикетки рисуются core-шрифтом Helvetica-Bold - его метрики совпадают с rack_labels,
// но кириллицы в нём нет (core-шрифты PDF - cp1252). Адрес с кириллицей печатается
// встроенным DejaVu Sans Condensed Bold (свободная лицензия Bitstream Vera, файл - из поставки
// go-pdf/fpdf); латинские адреса остаются на Helvetica, напечатанные этикетки не меняются.
//
//go:embed fonts/DejaVuSansCondensed-Bold.ttf
var cyrFontTTF []byte

const cyrFontName = "DejaVuCondBold"

// addCyrFont подключает шрифт кириллицы к документу; в PDF попадает только набор нужных букв.
func addCyrFont(pdf *fpdf.Fpdf) {
	pdf.AddUTF8FontFromBytes(cyrFontName, "", cyrFontTTF)
}

// needsCyrFont - в строке есть символы вне ASCII: core-шрифт их не нарисует.
func needsCyrFont(text string) bool {
	for _, r := range text {
		if r > 0x7e {
			return true
		}
	}
	return false
}

// setAddressFont - шрифт под строку адреса: Helvetica-Bold или, для кириллицы, DejaVu.
func setAddressFont(pdf *fpdf.Fpdf, text string, sizePt float64) {
	if needsCyrFont(text) {
		pdf.SetFont(cyrFontName, "", sizePt)
		return
	}
	pdf.SetFont(fontName, fontStyle, sizePt)
}
