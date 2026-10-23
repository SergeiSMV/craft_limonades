package service

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"sort"
	"strings"

	"craftwms/internal/model"
)

// Пределы раскрытия упаковки: сколько кодов в одном запросе к ЧЗ и сколько уровней вложенности.
// Паллета → короб → групповая упаковка → единица — три спуска; пять — с запасом, но не бесконечно,
// если ЧЗ вдруг вернёт цикл.
const (
	czChunk    = czMaxCodes
	czMaxDepth = 5
)

// Вид кода по виду строки. Марка или групповая упаковка различаются только ответом ЧЗ.
var (
	czBoxCode  = regexp.MustCompile(`^00[0-9]{18}$`)
	czCISCode  = regexp.MustCompile(`^01[0-9]{14}21.+$`)
	czAIMIdent = regexp.MustCompile(`^\][A-Za-z][0-9A-Za-z]`) // ]d2, ]C1, ]Q3 — префикс сканера
)

// NormalizeCZCode приводит скан к ключу ЧЗ: срезает префикс AIM, разделители GS по краям и
// криптохвост после GS. Возвращает ErrCZBadCode, если это ни марка, ни код короба.
//
// Зачем на сервере: ТСД отдаёт код как есть — с префиксом AIM, если сканер так настроен, и с
// GS внутри марки (DT50S, CZ-01). Разобрать в одном месте дешевле, чем в каждом клиенте.
func NormalizeCZCode(raw string) (string, error) {
	code := strings.Trim(strings.TrimSpace(raw), gs)
	code = czAIMIdent.ReplaceAllString(code, "")
	code = strings.TrimLeft(code, gs) // FNC1 сразу после префикса
	code, _, _ = strings.Cut(code, gs)
	if czBoxCode.MatchString(code) || czCISCode.MatchString(code) {
		return code, nil
	}
	return "", fmt.Errorf("%w: %q", model.ErrCZBadCode, raw)
}

// Scan — что ТСД показывает по скану марки или кода агрегата (CZ-04).
//
// Как: код → данные ЧЗ. Единица — товар по GTIN и что знает WMS о марке. Упаковка — её ГЕ,
// если это принятый короб, и состав, раскрытый до единиц и сведённый по товару и партии.
// Связь нужна всегда: ЧЗ читается только онлайн.
func (s *CZService) Scan(ctx context.Context, raw string) (model.CZScan, error) {
	if s.client == nil {
		return model.CZScan{}, model.ErrCZNotConfigured
	}
	code, err := NormalizeCZCode(raw)
	if err != nil {
		return model.CZScan{}, err
	}
	info, err := s.oneInfo(ctx, code)
	if err != nil {
		return model.CZScan{}, err
	}
	out := model.CZScan{Code: code, Info: info}

	if info.PackageType == "" || info.PackageType == "UNIT" {
		out.Good, out.BindBarcode, err = s.goodByGTIN(ctx, info.Gtin)
		if err != nil {
			return model.CZScan{}, err
		}
		out.Mark, err = s.markInWMS(ctx, code)
		return out, err
	}

	if info.PackageType == model.CZAggregateBox {
		if out.LoadUnitID, err = s.boxInWMS(ctx, code); err != nil {
			return model.CZScan{}, err
		}
	}
	if err := s.expand(ctx, info.Child, &out); err != nil {
		return model.CZScan{}, err
	}
	return out, nil
}

// oneInfo — ответ ЧЗ по одному коду. Отказ ЧЗ по коду в пакетном ответе — «не найден» с его
// текстом: кладовщику нужна причина, а не пустая карточка.
func (s *CZService) oneInfo(ctx context.Context, code string) (model.CisInfo, error) {
	items, err := s.client.CisesInfo(ctx, []string{code})
	if err != nil {
		return model.CisInfo{}, err
	}
	if len(items) == 0 {
		return model.CisInfo{}, fmt.Errorf("%w: %s", model.ErrCZNotFound, code)
	}
	it := items[0]
	if it.Cis == "" {
		return model.CisInfo{}, fmt.Errorf("%w: %s %s", model.ErrCZNotFound, code, it.ErrorMessage)
	}
	return it, nil
}

// goodByGTIN — товар справочника по GTIN; незнакомый GTIN — не ошибка: ТСД предложит
// привязать ШК (bind — EAN-13, GTIN-14 без ведущего нуля).
func (s *CZService) goodByGTIN(ctx context.Context, gtin string) (*model.CZGoodRef, string, error) {
	if gtin == "" || s.marks == nil {
		return nil, "", nil
	}
	g, err := s.marks.GoodByGTIN(ctx, gtin)
	if errors.Is(err, model.ErrCZUnknownGTIN) {
		return nil, ean13FromGTIN(gtin), nil
	}
	if err != nil {
		return nil, "", err
	}
	return &g, "", nil
}

// ean13FromGTIN — EAN-13 из GTIN-14 с ведущим нулём; иначе GTIN как есть.
func ean13FromGTIN(gtin string) string {
	if len(gtin) == 14 && gtin[0] == '0' {
		return gtin[1:]
	}
	return gtin
}

// markInWMS — марка в WMS; не числится — nil без ошибки.
func (s *CZService) markInWMS(ctx context.Context, cis string) (*model.CZMark, error) {
	if s.marks == nil {
		return nil, nil
	}
	m, err := s.marks.MarkByCIS(ctx, cis)
	if errors.Is(err, model.ErrCZMarkNotFound) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &m, nil
}

// boxInWMS — ГЕ принятого короба ЧЗ; короб не принят — пустая строка без ошибки.
func (s *CZService) boxInWMS(ctx context.Context, code string) (string, error) {
	if s.marks == nil {
		return "", nil
	}
	id, err := s.marks.LoadUnitByCZCode(ctx, code)
	if errors.Is(err, model.ErrCZAggregateNotFound) {
		return "", nil
	}
	return id, err
}

// expand раскрывает состав упаковки до единиц и сводит их по товару и партии.
//
// Как: ЧЗ по упаковке отдаёт только КИ вложенных. Они дочитываются пачками по czChunk; что
// оказалось упаковкой, спускается на уровень ниже. Единицы сводятся по GTIN и дате
// производства единицы — партии (ADR-0017). Товар по GTIN ищется один раз на GTIN.
func (s *CZService) expand(ctx context.Context, children []string, out *model.CZScan) error {
	type key struct{ gtin, date string }
	lines := map[key]*model.CZCompositionLine{}
	goods := map[string]*model.CZGoodRef{}

	level := children
	for depth := 0; len(level) > 0; depth++ {
		if depth == czMaxDepth {
			return fmt.Errorf("состав упаковки глубже %d уровней", czMaxDepth)
		}
		var next []string
		for start := 0; start < len(level); start += czChunk {
			items, err := s.client.CisesInfo(ctx, level[start:min(start+czChunk, len(level))])
			if err != nil {
				return err
			}
			for _, it := range items {
				switch {
				case it.Cis == "":
					out.Unreadable = append(out.Unreadable, it.RequestedCis)
				case it.PackageType == "" || it.PackageType == "UNIT":
					k := key{it.Gtin, dateOnly(it.ProducedDate)}
					ln, ok := lines[k]
					if !ok {
						good, known := goods[it.Gtin]
						if !known {
							g, _, err := s.goodByGTIN(ctx, it.Gtin)
							if err != nil {
								return err
							}
							goods[it.Gtin], good = g, g
						}
						ln = &model.CZCompositionLine{GTIN: it.Gtin, ProductName: it.ProductName,
							Good: good, ProducedDate: k.date}
						lines[k] = ln
					}
					ln.Count++
					ln.CIS = append(ln.CIS, it.Cis)
					out.Units++
				default:
					next = append(next, it.Child...)
				}
			}
		}
		level = next
	}

	out.Composition = make([]model.CZCompositionLine, 0, len(lines))
	for _, ln := range lines {
		sort.Strings(ln.CIS)
		out.Composition = append(out.Composition, *ln)
	}
	sort.Slice(out.Composition, func(i, j int) bool {
		a, b := out.Composition[i], out.Composition[j]
		if a.ProductName != b.ProductName {
			return a.ProductName < b.ProductName
		}
		return a.ProducedDate < b.ProducedDate
	})
	return nil
}

// dateOnly — дата из метки времени ЧЗ (`2026-10-12T00:00:00.000Z` → `2026-10-12`).
func dateOnly(ts string) string {
	if len(ts) >= 10 {
		return ts[:10]
	}
	return ts
}
