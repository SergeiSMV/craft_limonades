// Package labels — PDF адресных этикеток ячеек и карточек на стойку стеллажа (ADHOC-57).
//
// Геометрия перенесена из проекта rack_labels (config.yaml + render.py) один в один: тот же
// лист A4 с полями 10 мм и метками реза, этикетки на большую балку (4 на лист) и на малую
// (6 на лист), карточки на боковую опору (2 на лист), единый кегль на набор, Code128 вектором.
// Образец этикетки в портале рисуется по тем же числам. Все размеры — в миллиметрах.
package labels

import (
	"errors"
	"strings"
)

// Лист.
const (
	pageW     = 210.0
	pageH     = 297.0
	margin    = 10.0 // поля со всех сторон; рабочее поле 190 × 277
	cutLen    = 4.0  // длина метки реза на поле
	cutWidth  = 0.2
	workW     = pageW - 2*margin
	workH     = pageH - 2*margin
	capRatio  = 0.718 // высота прописной Helvetica-Bold к кеглю (как в rack_labels)
	ptToMM    = 25.4 / 72
	fontName  = "Helvetica"
	fontStyle = "B"
)

// Пороги считывания штрих-кода (validation в rack_labels).
const (
	minModule  = 0.25 // самый узкий штрих; уже — сканер промахивается
	quietRatio = 10.0 // защитная зона ≥ 10 модулей
	minFontPt  = 1.0  // меньше кегль адреса не уменьшается — тогда «не влезает»
)

// Стрелка «блоком»: стержень с головкой.
const (
	arrowShaft = 0.42 // ширина стержня от общей ширины
	arrowHead  = 0.55 // доля высоты под головку
)

// beamProfile — этикетка на балку: профиль large или small из config.yaml.
type beamProfile struct {
	rows    int     // этикеток на листе (одна колонка)
	pad     float64 // внутреннее поле
	gap     float64 // зазор между кодом, адресом и стрелкой
	capMax  float64 // высота прописной, потолок
	capMin  float64 // ниже — кегль уменьшается шагом 1 пт (fitSize)
	module  float64 // ширина модуля штрих-кода
	quiet   float64 // защитная зона кода с каждой стороны
	bcH     float64 // высота штрих-кода
	arrowW  float64
	arrowH  float64
	heightM float64 // высота этикетки
}

var (
	largeBeam = beamProfile{rows: 4, pad: 5, gap: 6, capMax: 26, capMin: 12, module: 0.30, quiet: 6, bcH: 26, arrowW: 22, arrowH: 26}
	smallBeam = beamProfile{rows: 6, pad: 4, gap: 4, capMax: 16, capMin: 9, module: 0.28, quiet: 5, bcH: 16, arrowW: 14, arrowH: 16}
)

func init() {
	largeBeam.heightM = workH / float64(largeBeam.rows)
	smallBeam.heightM = workH / float64(smallBeam.rows)
}

// Карточка на стойку (профиль side_card).
const (
	cardCols      = 2
	cardW         = 95.0
	cardH         = 277.0
	cardPad       = 8.0 // рабочее поле 79 × 261
	cardRadius    = 6.0
	cardBorder    = 0.6
	cardRowH      = 20.0
	cardCapMax    = 6.0
	cardCapMin    = 4.0
	cardGap       = 3.0  // между адресом и кодом
	cardBcW       = 42.0 // ширина кода вместе с защитными зонами
	cardBcH       = 14.0
	cardQuiet     = 3.0
	cardModuleMax = cardQuiet / quietRatio // 0,3 мм
	sepH          = 6.0                    // высота промежутка под пунктир между позициями
	sepWidth      = 0.5
	sepInset      = 6.0
	sepDash       = 3.0
	sepDashSpace  = 2.0
)

// FitError — содержимое не помещается или штрих-код нечитаем: печатать такое нельзя,
// лучше остановиться с перечнем причин, чем выдать пачку бракованных этикеток.
type FitError struct {
	Problems []string
}

func (e *FitError) Error() string {
	return "этикетки не печатаются: " + strings.Join(e.Problems, "; ")
}

// ErrNothingToPrint — в выборке нет ни одной этикетки этого вида.
var ErrNothingToPrint = errors.New("нечего печатать")

// measurer — ширина строки шрифтом Helvetica-Bold заданного кегля, мм. Метрики core-шрифта
// PDF — те же, что у reportlab, поэтому кегль совпадает с rack_labels.
type measurer func(text string, sizePt float64) float64

// fitSize — кегль (пт) строки: цель — capMax, ужимается по ширине avail ровно до неё.
// Если высота букв при этом ниже capMin, печать не останавливается: кегль берётся от capMin
// и уменьшается на 1 пт, пока строка не влезет (решение 2026-11-05 — длинный адрес мельче,
// но напечатан). ok=false — не влезает и на minFontPt: место съел штрих-код или стрелка.
func fitSize(text string, avail, capMax, capMin float64, width measurer) (float64, bool) {
	size := capMax / capRatio / ptToMM
	if w := width(text, size); w > avail {
		size *= avail / w
	}
	floor := capMin / capRatio / ptToMM
	if size >= floor-1e-6 {
		return size, true
	}
	size = floor
	for width(text, size) > avail+1e-9 && size-1 >= minFontPt {
		size--
	}
	return size, width(text, size) <= avail+1e-9
}

// widest — самая широкая строка набора: по ней считается единый кегль.
func widest(texts []string, width measurer) string {
	best, bestW := "", -1.0
	for _, t := range texts {
		if w := width(t, 100); w > bestW {
			best, bestW = t, w
		}
	}
	return best
}
