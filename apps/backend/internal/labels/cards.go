package labels

import (
	"fmt"
	"math"

	"github.com/go-pdf/fpdf"
)

// SideCards — PDF карточек на боковую опору стеллажа, по две на лист A4.
//
// Карточка — вертикальная полоса со всеми адресами стеллажа и их штрих-кодами: ячейки
// сканируют с неё, не подходя к каждой балке. Строки — в порядке cards (позиции убывают,
// внутри позиции ярусы сверху вниз), между позициями — пунктир. Строки разгоняются на всю
// высоту карточки: чем дальше коды друг от друга, тем меньше шанс считать соседний.
// Не влезающие строки уходят на продолжение карточки (overflow: split в config.yaml
// rack_labels; сам скрипт этого не делал, и лишние строки вылезали бы за край).
// set — адреса всех карточек склада: по ним единый кегль, чтобы карточки не разнились.
func SideCards(cards []Card, set []string) ([]byte, error) {
	var pieces []Card
	for _, c := range cards {
		pieces = append(pieces, splitCard(c)...)
	}
	if len(pieces) == 0 {
		return nil, ErrNothingToPrint
	}
	pdf, width := newPDF("Карточки на боковую опору стеллажа")

	addrW := cardW - 2*cardPad - cardGap - cardBcW
	texts := append([]string{}, set...)
	for _, c := range pieces {
		for _, r := range c.Rows {
			texts = append(texts, r.Address)
		}
	}
	w := widest(texts, width)
	size, ok := fitSize(w, addrW, cardCapMax, cardCapMin, width)
	var problems []string
	if !ok {
		problems = append(problems, fmt.Sprintf("адрес %s не влезает в карточку", w))
	}
	// Код в карточке растягивается на поле cardBcW, но модуль не шире cardModuleMax — иначе у
	// короткого адреса защитная зона 3 мм окажется меньше 10 модулей (у скрипта склад из одних
	// семизначных адресов не печатался). Порог «штрих не уже 0,25 мм» проверяется по самому
	// длинному коду набора склада — у него модуль самый узкий (check_geometry в rack_labels).
	longest, most := "", 0
	for _, a := range texts {
		n, err := c128Modules(a)
		if err != nil {
			problems = append(problems, err.Error())
			continue
		}
		if n > most {
			longest, most = a, n
		}
	}
	if most > 0 {
		problems = append(problems, moduleProblems(longest, cardModule(most), cardQuiet)...)
	}
	if len(problems) > 0 {
		return nil, &FitError{Problems: problems}
	}

	for i, c := range pieces {
		k := i % cardCols
		if k == 0 {
			pdf.AddPage()
		}
		if err := drawCard(pdf, margin+float64(k)*cardW, margin, c, size); err != nil {
			return nil, err
		}
	}
	return output(pdf)
}

// cardUsed — высота строк и пунктиров карточки без разгона.
func cardUsed(rows []CardRow) float64 {
	used := float64(len(rows)) * cardRowH
	for i := 1; i < len(rows); i++ {
		if rows[i].Position != rows[i-1].Position {
			used += sepH
		}
	}
	return used
}

// splitCard режет строки стеллажа на карточки, каждая из которых влезает в рабочее поле.
func splitCard(c Card) []Card {
	inner := cardH - 2*cardPad
	var out []Card
	var cur []CardRow
	for _, r := range c.Rows {
		if len(cur) > 0 && cardUsed(append(append([]CardRow{}, cur...), r)) > inner+1e-6 {
			out = append(out, Card{Rack: c.Rack, Rows: cur})
			cur = nil
		}
		cur = append(cur, r)
	}
	if len(cur) > 0 {
		out = append(out, Card{Rack: c.Rack, Rows: cur})
	}
	return out
}

// drawCard — одна карточка; (x, y) — левый верхний угол её колонки.
//
// Как в rack_labels: рамка со скруглением; свободное место делится поровну между всеми
// промежутками (над первой строкой, между строками и пунктирами, под последней).
func drawCard(pdf *fpdf.Fpdf, x, y float64, c Card, sizePt float64) error {
	pdf.SetDrawColor(0, 0, 0)
	pdf.SetLineWidth(cardBorder)
	pdf.SetDashPattern([]float64{}, 0)
	pdf.RoundedRect(x+1, y, cardW-2, cardH, cardRadius, "1234", "D")

	nSep := 0
	for i := 1; i < len(c.Rows); i++ {
		if c.Rows[i].Position != c.Rows[i-1].Position {
			nSep++
		}
	}
	slack := cardH - 2*cardPad - cardUsed(c.Rows)
	if slack < 0 {
		slack = 0
	}
	step := slack / float64(len(c.Rows)+nSep+1)
	cur := y + cardPad + step

	capH := sizePt * capRatio * ptToMM
	pdf.SetFillColor(0, 0, 0)
	for i, r := range c.Rows {
		if i > 0 && r.Position != c.Rows[i-1].Position {
			sy := cur + sepH/2
			pdf.SetLineWidth(sepWidth)
			pdf.SetDashPattern([]float64{sepDash, sepDashSpace}, 0)
			pdf.Line(x+sepInset, sy, x+cardW-sepInset, sy)
			pdf.SetDashPattern([]float64{}, 0)
			cur += sepH + step
		}
		pdf.SetFont(fontName, fontStyle, sizePt)
		pdf.Text(x+cardPad, cur+(cardRowH+capH)/2, r.Address)
		n, err := c128Modules(r.Address)
		if err != nil {
			return err
		}
		// Код прижат вправо: суженный короткий код стоит там же, где длинные, лишнее — в левую
		// защитную зону.
		module := cardModule(n)
		bx := x + cardW - cardPad - cardQuiet - float64(n)*module
		if err := drawBarcode(pdf, r.Address, bx, cur+(cardRowH-cardBcH)/2, module, cardBcH); err != nil {
			return err
		}
		cur += cardRowH + step
	}
	return nil
}

// cardModule — модуль кода карточки из n модулей: на всё поле кода, но не шире
// cardModuleMax (защитная зона cardQuiet — не меньше 10 модулей).
func cardModule(n int) float64 {
	return math.Min((cardBcW-2*cardQuiet)/float64(n), cardModuleMax)
}
