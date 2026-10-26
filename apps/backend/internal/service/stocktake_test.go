package service

import (
	"context"
	"errors"
	"slices"
	"testing"
	"time"

	"craftwms/internal/model"
)

type fakeStocktakeRepo struct {
	created []model.StocktakeCreateInput
}

func (f *fakeStocktakeRepo) Create(_ context.Context, in model.StocktakeCreateInput) (model.StocktakeCreated, error) {
	f.created = append(f.created, in)
	return model.StocktakeCreated{}, nil
}
func (f *fakeStocktakeRepo) Get(context.Context, string, string, time.Duration) (model.Stocktake, error) {
	return model.Stocktake{}, nil
}
func (f *fakeStocktakeRepo) Cells(context.Context, string, string, time.Duration) ([]model.StocktakeCell, error) {
	return nil, nil
}
func (f *fakeStocktakeRepo) Take(context.Context, string, string, time.Duration) error { return nil }
func (f *fakeStocktakeRepo) Release(context.Context, string, string) error             { return nil }
func (f *fakeStocktakeRepo) StartCount(context.Context, string, string) (model.StocktakeCellView, error) {
	return model.StocktakeCellView{}, nil
}
func (f *fakeStocktakeRepo) CellView(context.Context, string, string) (model.StocktakeCellView, error) {
	return model.StocktakeCellView{}, nil
}
func (f *fakeStocktakeRepo) Close(context.Context, string, string, bool) (int, error) { return 0, nil }

// P10-02: форма области проверяется до базы — вид известен, у «всего склада» объектов нет,
// у остальных они есть, всё — UUID; повторы объектов схлопываются.
func TestStocktakeService_createValidation(t *testing.T) {
	const (
		wh   = "8f4c2b1e-0d3a-4c5b-9e6f-1a2b3c4d5e6f"
		user = "1b2c3d4e-5f60-4a7b-8c9d-0e1f2a3b4c5d"
		obj  = "2c3d4e5f-6071-4b8c-9d0e-1f2a3b4c5d6e"
	)
	repo := &fakeStocktakeRepo{}
	svc := NewStocktakeService(repo)
	ctx := context.Background()

	for _, in := range []model.StocktakeCreateInput{
		{WarehouseID: wh, CreatedBy: user, ScopeKind: model.StocktakeScopeAll},
		{WarehouseID: wh, CreatedBy: user, ScopeKind: model.StocktakeScopeGroup, ObjectIDs: []string{obj, obj}},
	} {
		if _, err := svc.Create(ctx, in); err != nil {
			t.Errorf("%s: %v", in.ScopeKind, err)
		}
	}
	if got := repo.created[1].ObjectIDs; !slices.Equal(got, []string{obj}) {
		t.Errorf("повтор объекта не схлопнут: %v", got)
	}

	for name, in := range map[string]model.StocktakeCreateInput{
		"неизвестный вид":        {WarehouseID: wh, CreatedBy: user, ScopeKind: "matrix", ObjectIDs: []string{obj}},
		"весь склад с объектами": {WarehouseID: wh, CreatedBy: user, ScopeKind: model.StocktakeScopeAll, ObjectIDs: []string{obj}},
		"ячейки без объектов":    {WarehouseID: wh, CreatedBy: user, ScopeKind: model.StocktakeScopeCells},
		"объект не UUID":         {WarehouseID: wh, CreatedBy: user, ScopeKind: model.StocktakeScopeGood, ObjectIDs: []string{"x"}},
		"склад не UUID":          {WarehouseID: "x", CreatedBy: user, ScopeKind: model.StocktakeScopeAll},
		"без автора":             {WarehouseID: wh, ScopeKind: model.StocktakeScopeAll},
	} {
		if _, err := svc.Create(ctx, in); !errors.Is(err, model.ErrInvalidStocktake) {
			t.Errorf("%s: ожидался ErrInvalidStocktake, получено %v", name, err)
		}
	}
	if len(repo.created) != 2 {
		t.Errorf("до базы дошло %d пересчётов, ожидалось 2", len(repo.created))
	}
}
