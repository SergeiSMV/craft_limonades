package labels

import (
	"bytes"
	"fmt"

	"github.com/go-pdf/fpdf"
)

// Cell — ячейка для этикетки на балку.
type Cell struct {
	Address string
	IsFloor bool // нижняя ячейка: стрелка вниз справа от адреса
	Barcode bool // штрих-код слева от адреса
	QR      bool // QR слева от адреса вместо штрих-кода — напольная ячейка (ADHOC-61)
}

// codeKind — что стоит слева от адреса: ничего, Code128 или QR. По нему этикетки делятся на
// группы с общим кеглем: код отбирает ширину, и общий кегль срезал бы адрес там, где кода нет.
type codeKind int

const (
	codeNone codeKind = iota
	codeBar
	codeQR
)

func (c Cell) code() codeKind {
	switch {
	case c.QR:
		return codeQR
	case c.Barcode:
		return codeBar
	}
	return codeNone
}

// CardRow — строка карточки на стойку: адрес и позиция стеллажа (между позициями — пунктир).
type CardRow struct {
	Address  string
	Position int
}

// Card — карточка стеллажа: строки сверху вниз, как стеллаж выглядит из прохода.
type Card struct {
	Rack string
	Rows []CardRow
}

// newPDF — лист A4 без полей и автопереноса: всё раскладывается вручную в мм.
func newPDF(title string) (*fpdf.Fpdf, measurer) {
	pdf := fpdf.New("P", "mm", "A4", "")
	pdf.SetMargins(0, 0, 0)
	pdf.SetAutoPageBreak(false, 0)
	pdf.SetTitle(title, true)
	addCyrFont(pdf)
	pdf.SetFont(fontName, fontStyle, 10)
	return pdf, func(text string, sizePt float64) float64 {
		setAddressFont(pdf, text, sizePt)
		return pdf.GetStringWidth(text)
	}
}

func output(pdf *fpdf.Fpdf) ([]byte, error) {
	var buf bytes.Buffer
	if err := pdf.Output(&buf); err != nil {
		return nil, fmt.Errorf("вывод PDF: %w", err)
	}
	return buf.Bytes(), nil
}

// BeamLabels — PDF этикеток на балку одного размера (small — малая балка).
//
// items — что печатать, в порядке наклейки. set — все ячейки склада этого размера: по ним
// считается единый кегль (uniform_font), отдельно для этикеток со штрих-кодом и без — код
// отбирает ширину, и общий кегль срезал бы адрес там, где кода нет. Набор — весь склад, а не
// выборка печати: перепечатанная этикетка обязана совпасть с соседними на стеллаже.
// Не влезает или нечитаемый код — *FitError с причинами, PDF не строится.
func BeamLabels(small bool, items, set []Cell) ([]byte, error) {
	if len(items) == 0 {
		return nil, ErrNothingToPrint
	}
	p, title := largeBeam, "Адресные этикетки — большая балка"
	if small {
		p, title = smallBeam, "Адресные этикетки — малая балка"
	}
	pdf, width := newPDF(title)
	sizes, problems := beamSizes(p, set, width)
	for _, c := range items {
		if _, ok := sizes[c.code()]; !ok { // ячейка вне набора — считаем по ней самой
			s, pr := beamSizes(p, []Cell{c}, width)
			sizes[c.code()], problems = s[c.code()], append(problems, pr...)
		}
		if c.code() == codeBar {
			problems = append(problems, moduleProblems(c.Address, p.module, p.quiet)...)
		}
	}
	if len(problems) > 0 {
		return nil, &FitError{Problems: problems}
	}

	for i, c := range items {
		k := i % p.rows
		if k == 0 {
			pdf.AddPage()
			cutMarks(pdf, 1, p.rows, workW, p.heightM)
		}
		if err := drawBeam(pdf, margin, margin+float64(k)*p.heightM, workW, c, p, sizes[c.code()], width); err != nil {
			return nil, err
		}
	}
	return output(pdf)
}

// beamSizes — единый кегль (пт) по группам «без кода / штрих-код / QR» набора и причины, если не
// влезает.
func beamSizes(p beamProfile, set []Cell, width measurer) (map[codeKind]float64, []string) {
	sizes := map[codeKind]float64{}
	var problems []string
	for _, bc := range []codeKind{codeNone, codeBar, codeQR} {
		var texts []string
		arrow := false
		for _, c := range set {
			if c.code() == bc {
				texts = append(texts, c.Address)
				arrow = arrow || c.IsFloor
			}
		}
		if len(texts) == 0 {
			continue
		}
		w := widest(texts, width)
		avail := workW - 2*p.pad
		if arrow {
			avail -= p.arrowW + p.gap
		}
		switch bc {
		case codeBar:
			bw, err := barcodeWidth(w, p.module, p.quiet)
			if err != nil {
				problems = append(problems, err.Error())
				continue
			}
			avail -= bw + p.gap
		case codeQR:
			avail -= qrWidth(p) + p.gap
		}
		size, ok := fitSize(w, avail, p.capMax, p.capMin, width)
		if !ok {
			problems = append(problems, fmt.Sprintf("адрес %s не влезает рядом со штрих-кодом и стрелкой", w))
		}
		sizes[bc] = size
	}
	return sizes, problems
}

// barcodeWidth — полная ширина кода с защитными зонами, мм.
func barcodeWidth(value string, module, quiet float64) (float64, error) {
	n, err := c128Modules(value)
	if err != nil {
		return 0, err
	}
	return float64(n)*module + 2*quiet, nil
}

// moduleProblems — пороги считывания: модуль не уже 0,25 мм, защитная зона не меньше 10 модулей.
func moduleProblems(value string, module, quiet float64) []string {
	if _, err := c128Modules(value); err != nil {
		return []string{err.Error()}
	}
	var out []string
	if module < minModule-1e-9 {
		out = append(out, fmt.Sprintf("штрих-код %s: штрих %.3f мм уже %g мм — сканер будет промахиваться", value, module, minModule))
	}
	if quiet < quietRatio*module-1e-9 {
		out = append(out, fmt.Sprintf("штрих-код %s: защитная зона %g мм меньше %.2f мм", value, quiet, quietRatio*module))
	}
	return out
}

// drawBeam — одна этикетка на балку; (x, y) — левый верхний угол.
//
// Как в rack_labels: со штрих-кодом всё стоит в одну строку «код — адрес — стрелка»; если
// частей три — крайние прижаты к полям, адрес посередине между ними (код и стрелка стоят на
// одном месте у всех этикеток стеллажа), если две — строка по центру. Без кода — адрес и
// стрелка по центру.
func drawBeam(pdf *fpdf.Fpdf, x, y, w float64, c Cell, p beamProfile, sizePt float64, width measurer) error {
	cy := y + p.heightM/2
	capH := sizePt * capRatio * ptToMM
	textW := width(c.Address, sizePt)
	inner := w - 2*p.pad
	text := func(tx float64) {
		setAddressFont(pdf, c.Address, sizePt)
		pdf.Text(tx, cy+capH/2, c.Address)
	}
	pdf.SetFillColor(0, 0, 0)

	if c.code() == codeNone {
		band := textW
		if c.IsFloor {
			band += p.arrowW + p.gap
		}
		bx := x + (w-band)/2
		text(bx)
		if c.IsFloor {
			drawArrow(pdf, bx+textW+p.gap+p.arrowW/2, cy, p.arrowW, p.arrowH)
		}
		return nil
	}

	bcW := qrWidth(p)
	if c.code() == codeBar {
		var err error
		if bcW, err = barcodeWidth(c.Address, p.module, p.quiet); err != nil {
			return err
		}
	}
	type part struct {
		kind string
		w    float64
	}
	parts := []part{{"bc", bcW}, {"text", textW}}
	if c.IsFloor {
		parts = append(parts, part{"arrow", p.arrowW})
	}
	band := p.gap * float64(len(parts)-1)
	for _, pt := range parts {
		band += pt.w
	}
	if band > inner+1e-6 {
		return &FitError{Problems: []string{fmt.Sprintf("%s: строка %.1f мм шире поля этикетки %.1f мм", c.Address, band, inner)}}
	}
	cx, extra := x+(w-band)/2, 0.0
	if len(parts) > 2 {
		cx, extra = x+p.pad, (inner-band)/float64(len(parts)-1)
	}
	for _, pt := range parts {
		switch pt.kind {
		case "text":
			text(cx)
		case "bc":
			draw := func() error { return drawBarcode(pdf, c.Address, cx+p.quiet, cy-p.bcH/2, p.module, p.bcH) }
			if c.code() == codeQR {
				draw = func() error { return drawQR(pdf, c.Address, cx+p.quiet, cy-p.bcH/2, p.bcH) }
			}
			if err := draw(); err != nil {
				return err
			}
		default:
			drawArrow(pdf, cx+pt.w/2, cy, p.arrowW, p.arrowH)
		}
		cx += pt.w + p.gap + extra
	}
	return nil
}

// drawBarcode — Code128 вектором: штрихи — залитые прямоугольники; (x, y) — левый верхний угол
// первого штриха, без защитной зоны.
func drawBarcode(pdf *fpdf.Fpdf, value string, x, y, module, h float64) error {
	bars, err := c128Bars(value)
	if err != nil {
		return err
	}
	for _, b := range bars {
		pdf.Rect(x+float64(b[0])*module, y, float64(b[1])*module, h, "F")
	}
	return nil
}

// drawArrow — стрелка вниз «блоком» с центром (cx, cy): стержень и широкая головка.
func drawArrow(pdf *fpdf.Fpdf, cx, cy, w, h float64) {
	sw, head := w*arrowShaft, h*arrowHead
	top, bot := cy-h/2, cy+h/2
	y := bot - head
	pdf.Polygon([]fpdf.PointType{
		{X: cx - sw/2, Y: top}, {X: cx + sw/2, Y: top}, {X: cx + sw/2, Y: y},
		{X: cx + w/2, Y: y}, {X: cx, Y: bot}, {X: cx - w/2, Y: y}, {X: cx - sw/2, Y: y},
	}, "F")
}

// cutMarks — метки реза на полях листа по границам сетки cols × rows ячеек cw × ch.
func cutMarks(pdf *fpdf.Fpdf, cols, rows int, cw, ch float64) {
	pdf.SetLineWidth(cutWidth)
	pdf.SetDrawColor(0, 0, 0)
	for i := 0; i <= rows; i++ {
		yy := margin + float64(i)*ch
		pdf.Line(margin-cutLen, yy, margin, yy)
		pdf.Line(pageW-margin, yy, pageW-margin+cutLen, yy)
	}
	for j := 0; j <= cols; j++ {
		xx := margin + float64(j)*cw
		pdf.Line(xx, margin-cutLen, xx, margin)
		pdf.Line(xx, pageH-margin, xx, pageH-margin+cutLen)
	}
}
