package repository_test

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/google/uuid"

	"craftwms/internal/model"
	"craftwms/internal/repository"
)

// Тесты ADHOC-28: история перемещений всего склада для ТСД. Фикстура setupMove — из
// movement_integration_test.go.

// moveAs проводит перемещение от имени user.
func (mf *moveFixture) moveAs(t *testing.T, user, id string, lines ...repository.MovementLineInput) {
	t.Helper()
	if _, err := repository.MovementSubmitForTest(context.Background(), mf.pool, repository.MovementSubmitInput{
		MovementID: id, Kind: model.MovementMove, WarehouseID: mf.wh, CreatedBy: user, Lines: lines,
	}); err != nil {
		t.Fatalf("перемещение %s: %v", id, err)
	}
}

// Лента — всего склада, свежие сверху; фильтр по исполнителю и периоду; подгрузка курсором
// отдаёт следующую страницу без повторов; исполнители — все, кто перемещал.
func TestMovementHistory_listFilterAndCursor(t *testing.T) {
	mf := setupMove(t)
	ctx := context.Background()
	other := newUserNamed(t, mf.putawayFixture, "90000088", "Петров")
	lu := newLU(t, mf.stockFixture, model.LoadUnitBox)
	mf.receive(t, []string{lu}, 5)

	first, second, third := uuid.NewString(), uuid.NewString(), uuid.NewString()
	mf.moveAs(t, mf.user, first, luTo(lu, mf.cellB))
	mf.moveAs(t, other, second, mf.goodsLine(2, mf.cellA, "", mf.cellC, ""))
	mf.moveAs(t, mf.user, third, mf.goodsLine(1, mf.cellA, "", "", lu))

	repo := repository.NewMovementHistoryRepository(mf.pool)
	all, err := repo.List(ctx, model.MovementHistoryFilter{Limit: 10})
	mustNoErr(t, err)
	if len(all) != 3 || all[0].ID != third || all[1].ID != second || all[2].ID != first {
		t.Fatalf("лента: %+v", all)
	}
	if all[1].Executor.FullName != "Петров" || all[2].LoadUnits != 1 || all[2].Goods != 0 || all[0].Goods != 1 {
		t.Errorf("записи: %+v", all)
	}

	mine, err := repo.List(ctx, model.MovementHistoryFilter{ExecutorID: other, Limit: 10})
	mustNoErr(t, err)
	if len(mine) != 1 || mine[0].ID != second {
		t.Errorf("фильтр по исполнителю: %+v", mine)
	}

	yesterday := time.Now().Add(-24 * time.Hour)
	old, err := repo.List(ctx, model.MovementHistoryFilter{To: &yesterday, Limit: 10})
	mustNoErr(t, err)
	if len(old) != 0 {
		t.Errorf("период до вчера: %+v", old)
	}

	page1, err := repo.List(ctx, model.MovementHistoryFilter{Limit: 2})
	mustNoErr(t, err)
	last := page1[len(page1)-1]
	page2, err := repo.List(ctx, model.MovementHistoryFilter{BeforePostedAt: &last.PostedAt, BeforeID: last.ID, Limit: 2})
	mustNoErr(t, err)
	if len(page1) != 2 || len(page2) != 1 || page2[0].ID != first {
		t.Errorf("страницы: %+v / %+v", page1, page2)
	}

	executors, err := repo.Executors(ctx)
	mustNoErr(t, err)
	if len(executors) != 2 || executors[0].FullName != "Кладовщик" || executors[1].FullName != "Петров" {
		t.Errorf("исполнители: %+v", executors)
	}
}

// Запись показывает строки по порядку и с коробами — в том числе перекладывание внутри
// ячейки, которого нет в «Движении» для 1С.
func TestMovementHistory_getShowsBoxesAndInsideCell(t *testing.T) {
	mf := setupMove(t)
	ctx := context.Background()
	lu := newLU(t, mf.stockFixture, model.LoadUnitBox)
	mf.receive(t, []string{lu}, 5)

	mv := uuid.NewString()
	mf.moveAs(t, mf.user, mv,
		luTo(lu, mf.cellB),
		mf.goodsLine(4, "", lu, mf.cellB, ""),
	)

	d, err := repository.NewMovementHistoryRepository(mf.pool).Get(ctx, mv)
	mustNoErr(t, err)
	if d.Kind != model.MovementMove || d.Executor.FullName != "Кладовщик" || len(d.Lines) != 2 {
		t.Fatalf("запись: %+v", d)
	}
	box, goods := d.Lines[0], d.Lines[1]
	if box.LoadUnitID == nil || *box.LoadUnitID != lu || box.GoodID != nil ||
		box.FromCellAddress != "A" || box.ToCellAddress != "B" {
		t.Errorf("строка короба: %+v", box)
	}
	if goods.GoodName == nil || goods.Qty == nil || goods.Qty.String() != "4" ||
		goods.FromLoadUnitID == nil || *goods.FromLoadUnitID != lu || goods.ToLoadUnitID != nil ||
		goods.FromCellAddress != "B" || goods.ToCellAddress != "B" ||
		goods.ProductionDate == nil || goods.ProductionDate.Format(time.DateOnly) != "2026-01-01" {
		t.Errorf("строка товара: %+v", goods)
	}

	if _, err := repository.NewMovementHistoryRepository(mf.pool).Get(ctx, uuid.NewString()); !errors.Is(err, repository.ErrMovementNotFound) {
		t.Errorf("несуществующая запись: %v", err)
	}
}
