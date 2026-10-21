package repository_test

import (
	"context"
	"errors"
	"testing"

	"github.com/google/uuid"

	"craftwms/internal/repository"
)

// Тесты ADHOC-29: ведение справочника внутренних складов из портала. Фикстура setupMove —
// из movement_integration_test.go.

// Завести, повторить код, переименовать, скрыть и вернуть; склад по умолчанию не скрыть.
func TestInternalWarehouses_createUpdate(t *testing.T) {
	mf := setupMove(t)
	ctx := context.Background()
	repo := repository.NewInternalWarehouseRepository(mf.pool)

	created, err := repo.Create(ctx, "RECALL", "Возврат")
	mustNoErr(t, err)
	if created.Code != "RECALL" || !created.IsActive || created.IsDefault || created.InUse {
		t.Fatalf("заведённый склад: %+v", created)
	}
	if _, err := repo.Create(ctx, "RECALL", "Ещё возврат"); !errors.Is(err, repository.ErrInternalWarehouseExists) {
		t.Errorf("повтор кода: %v", err)
	}

	name, hidden := "Возврат поставщику", false
	updated, err := repo.Update(ctx, created.ID, &name, &hidden)
	mustNoErr(t, err)
	if updated.Name != name || updated.IsActive {
		t.Errorf("переименован и скрыт: %+v", updated)
	}
	shown := true
	if updated, err = repo.Update(ctx, created.ID, nil, &shown); err != nil || !updated.IsActive || updated.Name != name {
		t.Errorf("возвращён в выбор: %+v (%v)", updated, err)
	}

	if _, err := repo.Update(ctx, mf.iwh, nil, &hidden); !errors.Is(err, repository.ErrDefaultInternalWarehouse) {
		t.Errorf("скрыть склад по умолчанию: %v", err)
	}
	if _, err := repo.Update(ctx, uuid.NewString(), &name, nil); !errors.Is(err, repository.ErrUnknownInternalWarehouse) {
		t.Errorf("несуществующий склад: %v", err)
	}

	all, err := repo.All(ctx)
	mustNoErr(t, err)
	if len(all) < 4 || !all[0].IsDefault {
		t.Errorf("список: %+v", all)
	}
}

// Удалить можно только склад без остатка и истории; склад по умолчанию — никогда. Склад «в
// деле» помечен для портала заранее.
func TestInternalWarehouses_delete(t *testing.T) {
	mf := setupMove(t)
	ctx := context.Background()
	repo := repository.NewInternalWarehouseRepository(mf.pool)

	unused, err := repo.Create(ctx, "TEMP", "Временный")
	mustNoErr(t, err)
	mustNoErr(t, repo.Delete(ctx, unused.ID))
	if err := repo.Delete(ctx, unused.ID); !errors.Is(err, repository.ErrUnknownInternalWarehouse) {
		t.Errorf("повторное удаление: %v", err)
	}

	// Брак с остатком — после пометки россыпи.
	defect := mf.iwhByCode(t, "DEFECT")
	mf.receive(t, nil, 5)
	mustNoErr(t, mf.problem(t, defect, mf.goodsProblem(1, mf.cellA, "")))
	all, err := repo.All(ctx)
	mustNoErr(t, err)
	inUse := map[string]bool{}
	for _, w := range all {
		inUse[w.Code] = w.InUse
	}
	if !inUse["DEFECT"] || !inUse["MAIN"] || inUse["ISOLATOR"] {
		t.Errorf("признак «в деле»: %v", inUse)
	}
	if err := repo.Delete(ctx, defect); !errors.Is(err, repository.ErrInternalWarehouseInUse) {
		t.Errorf("удалить склад с остатком: %v", err)
	}
	if err := repo.Delete(ctx, mf.iwh); !errors.Is(err, repository.ErrDefaultInternalWarehouse) {
		t.Errorf("удалить склад по умолчанию: %v", err)
	}
	mustNoErr(t, repo.Delete(ctx, mf.iwhByCode(t, "ISOLATOR")))
	if mf.qtyIn(t, mf.cellA, defect) != "1" {
		t.Error("отказы сдвинули остаток")
	}
}
