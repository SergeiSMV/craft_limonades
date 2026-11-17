package labels

import "fmt"

// Code128, набор B - штрих-код адреса ячейки. Свой кодировщик, а не библиотечный: библиотеки
// переходят на набор C на цифрах по своим правилам, и ширина кода (а с ней кегль адреса)
// расходилась бы с rack_labels (reportlab) и с образцом этикетки в портале. Набор B кодирует
// адрес из латиницы, цифр и дефисов одинаково везде: старт, символы, контрольный, стоп.

// c128Patterns - шаблоны символов 0…106 (как в reportlab): заглавная буква - штрих, строчная -
// пробел; буква - ширина в модулях (A = 1 … D = 4).
var c128Patterns = [107]string{
	"BaBbBb", "BbBaBb", "BbBbBa", "AbAbBc", "AbAcBb", "AcAbBb", "AbBbAc", "AbBcAb",
	"AcBbAb", "BbAbAc", "BbAcAb", "BcAbAb", "AaBbCb", "AbBaCb", "AbBbCa", "AaCbBb",
	"AbCaBb", "AbCbBa", "BbCbAa", "BbAaCb", "BbAbCa", "BaCbAb", "BbCaAb", "CaBaCa",
	"CaAbBb", "CbAaBb", "CbAbBa", "CaBbAb", "CbBaAb", "CbBbAa", "BaBaBc", "BaBcBa",
	"BcBaBa", "AaAcBc", "AcAaBc", "AcAcBa", "AaBcAc", "AcBaAc", "AcBcAa", "BaAcAc",
	"BcAaAc", "BcAcAa", "AaBaCc", "AaBcCa", "AcBaCa", "AaCaBc", "AaCcBa", "AcCaBa",
	"CaCaBa", "BaAcCa", "BcAaCa", "BaCaAc", "BaCcAa", "BaCaCa", "CaAaBc", "CaAcBa",
	"CcAaBa", "CaBaAc", "CaBcAa", "CcBaAa", "CaDaAa", "BbAdAa", "DcAaAa", "AaAbBd",
	"AaAdBb", "AbAaBd", "AbAdBa", "AdAaBb", "AdAbBa", "AaBbAd", "AaBdAb", "AbBaAd",
	"AbBdAa", "AdBaAb", "AdBbAa", "BdAbAa", "BbAaAd", "DaCaAa", "BdAaAb", "AcDaAa",
	"AaAbDb", "AbAaDb", "AbAbDa", "AaDbAb", "AbDaAb", "AbDbAa", "DaAbAb", "DbAaAb",
	"DbAbAa", "BaBaDa", "BaDaBa", "DaBaBa", "AaAaDc", "AaAcDa", "AcAaDa", "AaDaAc",
	"AaDcAa", "DaAaAc", "DaAcAa", "AaCaDa", "AaDaCa", "CaAaDa", "DaAaCa", "BaAdAb",
	"BaAbAd", "BaAbCb", "BcCaAaB",
}

const (
	c128StartB = 104
	c128Stop   = 106
)

// c128Codes - коды символов: старт B, символы, контрольный, стоп. Символ вне ASCII 32…127
// (кириллица, «С-Н-П») набором B не кодируется - ошибка, а не молча испорченный код.
func c128Codes(value string) ([]int, error) {
	codes := []int{c128StartB}
	sum := c128StartB
	pos := 0
	for _, r := range value {
		if r < 32 || r > 127 {
			return nil, fmt.Errorf("в адресе %q символ %q не кодируется Code128", value, r)
		}
		pos++
		codes = append(codes, int(r)-32)
		sum += (int(r) - 32) * pos
	}
	return append(codes, sum%103, c128Stop), nil
}

// c128Modules - ширина кода в модулях (без защитных зон).
func c128Modules(value string) (int, error) {
	codes, err := c128Codes(value)
	if err != nil {
		return 0, err
	}
	n := 0
	for _, c := range codes {
		for _, ch := range c128Patterns[c] {
			n += moduleWidth(ch)
		}
	}
	return n, nil
}

// c128Bars - штрихи кода: смещение от начала и ширина, в модулях.
func c128Bars(value string) ([][2]int, error) {
	codes, err := c128Codes(value)
	if err != nil {
		return nil, err
	}
	var bars [][2]int
	x := 0
	for _, c := range codes {
		for _, ch := range c128Patterns[c] {
			w := moduleWidth(ch)
			if ch >= 'A' && ch <= 'Z' {
				bars = append(bars, [2]int{x, w})
			}
			x += w
		}
	}
	return bars, nil
}

// moduleWidth - ширина элемента шаблона в модулях: A/a = 1 … D/d = 4.
func moduleWidth(ch rune) int {
	if ch >= 'a' {
		return int(ch-'a') + 1
	}
	return int(ch-'A') + 1
}
