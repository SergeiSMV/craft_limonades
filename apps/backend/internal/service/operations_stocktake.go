package service

import (
	"context"
	"encoding/json"
	"slices"
	"strings"

	"github.com/shopspring/decimal"

	"craftwms/internal/model"
	"craftwms/internal/repository"
)

// stocktakeCellSubmitPayload - тело операции stocktake_cell_submit, как его собирает ТСД (P10-03).
//
// `loose` - факт россыпи по позиции: товар, партия датой, склад (пусто - «Основной»),
// количество, у маркируемого товара - найденные марки. `boxes` - найденные короба. Позиция
// снимка, которой нет ни там, ни там, - недостача.
type stocktakeCellSubmitPayload struct {
	StocktakeCellID string `json:"stocktake_cell_id"`
	Loose           []struct {
		GoodID              string          `json:"good_id"`
		ProductionDate      string          `json:"production_date"`
		InternalWarehouseID string          `json:"internal_warehouse_id"`
		Qty                 decimal.Decimal `json:"qty"`
		Marks               []string        `json:"marks"`
	} `json:"loose"`
	Boxes []string `json:"boxes"`
}

// stocktakeCellSubmit разбирает и проверяет подсчёт ячейки пересчёта (P10-03).
//
// Здесь - всё, что проверяется без базы: идентификаторы, дата, неотрицательное количество, одна
// позиция и один короб - один раз, марка - одна на весь подсчёт. Работник - из токена.
func (s *OperationsService) stocktakeCellSubmit(ctx context.Context, userID, id string, raw json.RawMessage) (repository.Applied, error) {
	var p stocktakeCellSubmitPayload
	if err := json.Unmarshal(raw, &p); err != nil {
		return repository.Applied{}, model.ErrInvalidPayload
	}
	in := model.StocktakeCellSubmitInput{StocktakeCellID: strings.TrimSpace(p.StocktakeCellID), UserID: userID}
	if !isUUID(in.StocktakeCellID) {
		return repository.Applied{}, model.ErrInvalidPayload
	}

	type posKey struct{ good, date, iwh string }
	seen := map[posKey]bool{}
	var marks []string
	for _, ln := range p.Loose {
		f := model.StocktakeLooseFact{
			GoodID:              strings.TrimSpace(ln.GoodID),
			InternalWarehouseID: strings.TrimSpace(ln.InternalWarehouseID),
			Qty:                 ln.Qty,
		}
		if !isUUID(f.GoodID) || !isOptionalUUID(f.InternalWarehouseID) {
			return repository.Applied{}, model.ErrInvalidPayload
		}
		if f.Qty.IsNegative() {
			return repository.Applied{}, model.ErrInvalidQuantity
		}
		iso, err := parseEntryDate(ln.ProductionDate)
		if err != nil {
			return repository.Applied{}, err
		}
		f.ProductionDate = iso
		k := posKey{f.GoodID, iso, f.InternalWarehouseID}
		if seen[k] {
			return repository.Applied{}, model.ErrInvalidPayload
		}
		seen[k] = true
		for _, m := range ln.Marks {
			m = strings.TrimSpace(m)
			if m == "" || slices.Contains(marks, m) {
				return repository.Applied{}, model.ErrInvalidPayload
			}
			marks = append(marks, m)
			f.Marks = append(f.Marks, m)
		}
		in.Loose = append(in.Loose, f)
	}
	for _, lu := range p.Boxes {
		lu = strings.TrimSpace(lu)
		if !isUUID(lu) || slices.Contains(in.Boxes, lu) {
			return repository.Applied{}, model.ErrInvalidPayload
		}
		in.Boxes = append(in.Boxes, lu)
	}
	return s.repo.StocktakeCellSubmit(ctx, id, in)
}
