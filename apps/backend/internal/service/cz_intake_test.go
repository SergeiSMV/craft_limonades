package service

import (
	"errors"
	"testing"

	"github.com/shopspring/decimal"

	"craftwms/internal/model"
	"craftwms/internal/repository"
)

// Проверки формы данных ЧЗ приёмки (CZ-05) - до базы, отказом по существу.
func TestReceiptCZ_formChecks(t *testing.T) {
	const (
		box   = "00146127282000000172"
		group = "0114612728200179215G1"
		mark  = "0104612728200172215M1"
		lu    = "4e000000-0000-4000-8000-000000000002"
	)
	lus := []repository.LoadUnitInput{{ID: lu, Kind: model.LoadUnitBox, CZCode: box}}
	two := decimal.NewFromInt(2)

	cases := []struct {
		name   string
		groups []czGroupPayload
		marks  []czMarkPayload
		lineLU string
		want   error
	}{
		{name: "марка короба в его строке", groups: []czGroupPayload{{Code: group, ParentCode: box}},
			marks: []czMarkPayload{{CIS: mark, AggregateCode: group}}, lineLU: lu},
		{name: "марка короба россыпью", groups: []czGroupPayload{{Code: group, ParentCode: box}},
			marks: []czMarkPayload{{CIS: mark, AggregateCode: group}}, want: ErrInvalidPayload},
		{name: "упаковка вне приёмки", groups: []czGroupPayload{{Code: group, ParentCode: "00999999999999999999"}},
			want: ErrInvalidPayload},
		{name: "упаковки по кругу", groups: []czGroupPayload{
			{Code: group, ParentCode: group + "2"}, {Code: group + "2", ParentCode: group}}, want: ErrInvalidPayload},
		{name: "чужая причина", marks: []czMarkPayload{{CIS: mark, Discrepancy: "broken"}}, want: ErrInvalidPayload},
		{name: "КИ не по форме", marks: []czMarkPayload{{CIS: "4612728200172"}}, want: model.ErrCZBadCode},
		{name: "повтор марки", marks: []czMarkPayload{{CIS: mark}, {CIS: mark}}, want: model.ErrCZMarkExists},
		{name: "марок больше количества", marks: []czMarkPayload{{CIS: mark}, {CIS: mark + "2"}, {CIS: mark + "3"}},
			want: model.ErrCZMarksExceedQty},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			cz, err := newCZIntake(lus, tc.groups)
			if err == nil {
				_, err = cz.marks(tc.marks, tc.lineLU, two)
			}
			if !errors.Is(err, tc.want) { // errors.Is(nil, nil) - true
				t.Fatalf("ошибка %v, ожидалась %v", err, tc.want)
			}
		})
	}
}
