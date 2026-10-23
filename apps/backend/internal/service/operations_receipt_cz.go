package service

import (
	"fmt"
	"strings"

	"github.com/shopspring/decimal"

	"craftwms/internal/model"
	"craftwms/internal/repository"
)

// receiptCZGroupPayload — групповая упаковка ЧЗ в теле приёмки (CZ-05).
type receiptCZGroupPayload struct {
	Code       string `json:"code"`
	ParentCode string `json:"parent_code"` // короб или упаковка той же приёмки; пусто — сама по себе
}

// receiptMarkPayload — марка ЧЗ строки приёмки (CZ-05).
type receiptMarkPayload struct {
	CIS           string `json:"cis"`
	AggregateCode string `json:"aggregate_code"` // упаковка ЧЗ той же приёмки; пусто — россыпью
	Discrepancy   string `json:"discrepancy"`    // расхождение со скана; пусто — нет
}

// czMaxNesting — предел спуска от упаковки к коробу: короб → упаковка → упаковка с запасом.
// Цикл parent_code в теле — испорченная операция, а не повод зависнуть.
const czMaxNesting = 5

// receiptCZ — проверка данных ЧЗ приёмки без базы (CZ-05).
//
// Что: коды коробов и упаковок по форме, вложенность упаковок только в упаковки той же
// приёмки, марки — по форме, без повторов, в своём коробе и не больше количества строки.
// Зачем здесь: всё это ошибка формы — отказ до открытия транзакции, а не нарушение ключа на
// середине вставки. Совпадение GTIN марки с товаром строки проверяет проводка: нужна база.
type receiptCZ struct {
	parent map[string]string // код упаковки → в какой упаковке лежит ("" — верхний уровень)
	boxLU  map[string]string // код короба ЧЗ → его ГЕ
	seen   map[string]bool   // КИ, уже встреченные в теле
	groups []model.CZAggregate
}

// newReceiptCZ собирает коробы ЧЗ приёмки из её ГЕ и проверяет групповые упаковки.
func newReceiptCZ(lus []repository.LoadUnitInput, groups []receiptCZGroupPayload) (*receiptCZ, error) {
	c := &receiptCZ{parent: map[string]string{}, boxLU: map[string]string{}, seen: map[string]bool{}}
	for _, lu := range lus {
		if lu.CZCode == "" {
			continue
		}
		if !czBoxCode.MatchString(lu.CZCode) {
			return nil, fmt.Errorf("%w: %q", model.ErrCZBadCode, lu.CZCode)
		}
		if _, dup := c.parent[lu.CZCode]; dup {
			return nil, fmt.Errorf("%w: %s", model.ErrCZAggregateExists, lu.CZCode)
		}
		c.parent[lu.CZCode] = ""
		c.boxLU[lu.CZCode] = lu.ID
	}
	for _, g := range groups {
		code := strings.TrimSpace(g.Code)
		if !czCISCode.MatchString(code) || strings.Contains(code, gs) {
			return nil, fmt.Errorf("%w: %q", model.ErrCZBadCode, g.Code)
		}
		if _, dup := c.parent[code]; dup {
			return nil, fmt.Errorf("%w: %s", model.ErrCZAggregateExists, code)
		}
		c.parent[code] = strings.TrimSpace(g.ParentCode)
		c.groups = append(c.groups, model.CZAggregate{
			Code: code, Kind: model.CZAggregateGroup, ParentCode: c.parent[code],
		})
	}
	// Родитель — упаковка той же приёмки; иначе ссылка в никуда упёрлась бы во внешний ключ.
	for _, g := range c.groups {
		if _, err := c.rootBox(g.Code); err != nil {
			return nil, err
		}
	}
	return c, nil
}

// rootBox — короб ЧЗ, в котором (через упаковки) лежит упаковка code; пусто — ни в каком.
func (c *receiptCZ) rootBox(code string) (string, error) {
	for range czMaxNesting {
		parent, ok := c.parent[code]
		if !ok {
			return "", ErrInvalidPayload
		}
		if parent == "" {
			if _, box := c.boxLU[code]; box {
				return code, nil
			}
			return "", nil
		}
		code = parent
	}
	return "", ErrInvalidPayload
}

// marks проверяет марки строки: форма КИ, расхождение из списка, упаковка — той же приёмки,
// марка из короба ЧЗ — в строке этого короба, без повторов по всему телу, не больше qty.
func (c *receiptCZ) marks(in []receiptMarkPayload, lineLU string, qty decimal.Decimal) ([]model.ReceiptMark, error) {
	if len(in) == 0 {
		return nil, nil
	}
	if decimal.NewFromInt(int64(len(in))).GreaterThan(qty) {
		return nil, model.ErrCZMarksExceedQty
	}
	out := make([]model.ReceiptMark, 0, len(in))
	for _, m := range in {
		mark := model.ReceiptMark{
			CIS:           strings.TrimSpace(m.CIS),
			AggregateCode: strings.TrimSpace(m.AggregateCode),
			Discrepancy:   strings.TrimSpace(m.Discrepancy),
		}
		if !czCISCode.MatchString(mark.CIS) || strings.Contains(mark.CIS, gs) {
			return nil, fmt.Errorf("%w: %q", model.ErrCZBadCode, m.CIS)
		}
		if c.seen[mark.CIS] {
			return nil, fmt.Errorf("%w: %s", model.ErrCZMarkExists, mark.CIS)
		}
		c.seen[mark.CIS] = true
		switch mark.Discrepancy {
		case "", model.CZDiscrepancyForeignMark, model.CZDiscrepancyRetired:
		default:
			return nil, ErrInvalidPayload
		}
		if mark.AggregateCode != "" {
			box, err := c.rootBox(mark.AggregateCode)
			if err != nil {
				return nil, err
			}
			// Короб ЧЗ — это ГЕ: его марка не может лежать россыпью или в чужом коробе.
			if box != "" && c.boxLU[box] != lineLU {
				return nil, ErrInvalidPayload
			}
		}
		out = append(out, mark)
	}
	return out, nil
}
