package repository_test

import (
	"context"
	"errors"
	"testing"

	"github.com/google/uuid"

	"craftwms/internal/model"
	"craftwms/internal/repository"
)

// Тесты P5-05: просмотр содержимого ячеек и коробов. Фикстура размещения: A — ячейка
// приёмки, B — ячейка хранения; короба по 12 шт.

// setupContents: два короба и россыпь 5 шт приняты в A, первый короб размещён в B.
// В A остаются второй короб и россыпь, в B — первый короб.
func setupContents(t *testing.T) (pf *putawayFixture, boxB, boxA string) {
	t.Helper()
	pf = setupPutaway(t)
	boxB = newLU(t, pf.stockFixture, model.LoadUnitBox)
	boxA = newLU(t, pf.stockFixture, model.LoadUnitBox)
	task := pf.receive(t, []string{boxB, boxA}, 5)
	if _, err := pf.submit(t, task, uuid.NewString(), boxTo(boxB, pf.cellB)); err != nil {
		t.Fatalf("размещение короба: %v", err)
	}
	return pf, boxB, boxA
}

// Снимок: только живые короба, каждый в своей ячейке; россыпь за вычетом коробов.
func TestContents_snapshot(t *testing.T) {
	pf, boxB, boxA := setupContents(t)
	// Короб без приёмки — не размещён и пуст: в снимок не попадает.
	idle := newLU(t, pf.stockFixture, model.LoadUnitBox)

	snap, err := repository.NewContentsRepository(pf.pool).Snapshot(context.Background())
	mustNoErr(t, err)

	if snap.AsOf.IsZero() {
		t.Error("у снимка нет момента")
	}
	cells := map[string]string{}
	for _, lu := range snap.LoadUnits {
		if !lu.Live || lu.CellID == nil || len(lu.Contents) != 1 || lu.Contents[0].Qty.String() != "12" {
			t.Errorf("короб снимка %+v", lu)
			continue
		}
		cells[lu.ID] = *lu.CellID
	}
	if len(cells) != 2 || cells[boxB] != pf.cellB || cells[boxA] != pf.cellA {
		t.Errorf("короба снимка %v, ожидалось %s→B, %s→A", cells, boxB, boxA)
	}
	if _, ok := cells[idle]; ok {
		t.Error("неразмещённый пустой короб попал в снимок")
	}
	// В A лежит 12 + 5, из них 12 в коробе — россыпь 5; в B всё в коробе — россыпи нет.
	if len(snap.Loose) != 1 || snap.Loose[0].CellID != pf.cellA || snap.Loose[0].Qty.String() != "5" ||
		snap.Loose[0].InternalWarehouseID != pf.iwh {
		t.Errorf("россыпь снимка %+v, ожидалось 5 шт в A", snap.Loose)
	}
}

// Содержимое ячейки: свои короба и своя россыпь; неизвестная ячейка — ErrCellNotFound.
func TestContents_cell(t *testing.T) {
	pf, boxB, boxA := setupContents(t)
	repo := repository.NewContentsRepository(pf.pool)
	ctx := context.Background()

	a, err := repo.CellContents(ctx, pf.cellA)
	mustNoErr(t, err)
	if len(a.LoadUnits) != 1 || a.LoadUnits[0].ID != boxA || len(a.Loose) != 1 || a.Loose[0].Qty.String() != "5" {
		t.Errorf("ячейка A: короба %+v, россыпь %+v", a.LoadUnits, a.Loose)
	}
	if a.Address == "" || a.WarehouseID != pf.wh {
		t.Errorf("шапка ячейки A: %q, склад %q", a.Address, a.WarehouseID)
	}

	b, err := repo.CellContents(ctx, pf.cellB)
	mustNoErr(t, err)
	if len(b.LoadUnits) != 1 || b.LoadUnits[0].ID != boxB || len(b.Loose) != 0 {
		t.Errorf("ячейка B: короба %+v, россыпь %+v", b.LoadUnits, b.Loose)
	}
	if b.LoadUnits[0].CellAddress == nil || *b.LoadUnits[0].CellAddress != b.Address {
		t.Errorf("адрес короба в B: %v", b.LoadUnits[0].CellAddress)
	}

	if _, err := repo.CellContents(ctx, uuid.NewString()); !errors.Is(err, model.ErrCellNotFound) {
		t.Errorf("неизвестная ячейка: %v, ожидалось ErrCellNotFound", err)
	}
}

// Карточка короба: живой — с ячейкой и содержимым; неживой — есть, но помечен;
// неизвестный — ErrLoadUnitNotFound, тот же, что у приёмки.
func TestContents_loadUnitCard(t *testing.T) {
	pf, boxB, _ := setupContents(t)
	repo := repository.NewContentsRepository(pf.pool)
	ctx := context.Background()

	card, err := repo.LoadUnitCard(ctx, boxB)
	mustNoErr(t, err)
	if !card.Live || card.CellID == nil || *card.CellID != pf.cellB || card.CellAddress == nil ||
		len(card.Contents) != 1 || card.Contents[0].GoodID != pf.good || card.Contents[0].BatchID != pf.batch {
		t.Errorf("живой короб: %+v", card)
	}

	idle := newLU(t, pf.stockFixture, model.LoadUnitBox)
	card, err = repo.LoadUnitCard(ctx, idle)
	mustNoErr(t, err)
	if card.Live || card.CellID != nil || len(card.Contents) != 0 {
		t.Errorf("неразмещённый короб: %+v", card)
	}

	_, err = repo.LoadUnitCard(ctx, uuid.NewString())
	if !errors.Is(err, model.ErrLoadUnitNotFound) || !errors.Is(err, repository.ErrLoadUnitNotFound) {
		t.Errorf("неизвестный короб: %v", err)
	}
}

// Россыпь просмотра и россыпь размещения — один расчёт: в ячейке приёмки лежит 17 шт,
// из них 12 в коробе; просмотр показывает 5, размещение их принимает, и после этого россыпи
// в ячейке нет, а короб на месте.
func TestContents_looseAgreesWithPutaway(t *testing.T) {
	pf := setupPutaway(t)
	lu := newLU(t, pf.stockFixture, model.LoadUnitBox)
	task := pf.receive(t, []string{lu}, 5)
	repo := repository.NewContentsRepository(pf.pool)
	ctx := context.Background()

	a, err := repo.CellContents(ctx, pf.cellA)
	mustNoErr(t, err)
	if len(a.Loose) != 1 || a.Loose[0].Qty.String() != "5" {
		t.Fatalf("россыпь в A: %+v, ожидалось 5", a.Loose)
	}

	if _, err := pf.submit(t, task, uuid.NewString(), looseTo(pf.good, 5, pf.cellB)); err != nil {
		t.Fatalf("показанная россыпь не размещается: %v", err)
	}

	a, err = repo.CellContents(ctx, pf.cellA)
	mustNoErr(t, err)
	if len(a.Loose) != 0 || len(a.LoadUnits) != 1 {
		t.Errorf("A после размещения россыпи: короба %+v, россыпь %+v", a.LoadUnits, a.Loose)
	}
}
