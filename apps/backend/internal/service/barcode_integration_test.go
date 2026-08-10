package service_test

import (
	"context"
	"errors"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"

	"craftwms/internal/repository"
	"craftwms/internal/service"
	"craftwms/internal/testutil"
)

// newBarcodeSvc + фикстуры товаров для тестов привязки ШК.
func newBarcodeSvc(pool *pgxpool.Pool) *service.BarcodeService {
	return service.NewBarcodeService(repository.NewBarcodeRepository(pool))
}

// seedGood вставляет товар напрямую и возвращает его id.
func seedGood(t *testing.T, pool *pgxpool.Pool, name string) string {
	t.Helper()
	var id string
	err := pool.QueryRow(context.Background(),
		`INSERT INTO goods (name, uom) VALUES ($1,'шт') RETURNING id::text`, name).Scan(&id)
	if err != nil {
		t.Fatalf("seed good %q: %v", name, err)
	}
	return id
}

// TestBarcode_bindResolve — привязка и резолв: 200-путь, идемпотентность, мульти-ШК на товар.
func TestBarcode_bindResolve(t *testing.T) {
	pool := testutil.StartPostgres(t)
	svc := newBarcodeSvc(pool)
	ctx := context.Background()

	goodA := seedGood(t, pool, "Товар A")

	// Привязка нового ШК → ресолвится в товар A.
	if err := svc.Bind(ctx, goodA, "4600000000017", "ean13"); err != nil {
		t.Fatalf("Bind: %v", err)
	}
	got, err := svc.ResolveGood(ctx, "4600000000017")
	if err != nil {
		t.Fatalf("ResolveGood: %v", err)
	}
	if got.ID != goodA {
		t.Fatalf("резолв ШК: ожидался товар %s, получен %s", goodA, got.ID)
	}

	// Идемпотентность: повторная привязка того же ШК к тому же товару — без ошибки.
	if err := svc.Bind(ctx, goodA, "4600000000017", "ean13"); err != nil {
		t.Fatalf("повторная привязка того же ШК должна быть идемпотентной, получено %v", err)
	}

	// Мульти-ШК: второй ШК тому же товару — норма (товар накапливает ШК).
	if err := svc.Bind(ctx, goodA, "4600000000024", ""); err != nil {
		t.Fatalf("второй ШК тому же товару: %v", err)
	}
	got2, err := svc.ResolveGood(ctx, "4600000000024")
	if err != nil || got2.ID != goodA {
		t.Fatalf("второй ШК должен резолвиться в тот же товар A: id=%s err=%v", got2.ID, err)
	}

	// Итог: у товара A ровно 2 ШК.
	var cnt int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM barcodes WHERE good_id=$1::uuid`, goodA).Scan(&cnt); err != nil {
		t.Fatalf("count barcodes: %v", err)
	}
	if cnt != 2 {
		t.Fatalf("ожидалось 2 ШК у товара, получено %d", cnt)
	}
}

// TestBarcode_resolveUnknown_notFound — 404-путь: ШК не привязан.
func TestBarcode_resolveUnknown_notFound(t *testing.T) {
	pool := testutil.StartPostgres(t)
	svc := newBarcodeSvc(pool)

	_, err := svc.ResolveGood(context.Background(), "0000000000000")
	if !errors.Is(err, repository.ErrNotFound) {
		t.Fatalf("ожидалась repository.ErrNotFound (→404), получено %v", err)
	}
}

// TestBarcode_conflict — 409-путь: занятый ШК другим товаром.
func TestBarcode_conflict(t *testing.T) {
	pool := testutil.StartPostgres(t)
	svc := newBarcodeSvc(pool)
	ctx := context.Background()

	goodA := seedGood(t, pool, "Товар A")
	goodB := seedGood(t, pool, "Товар B")

	if err := svc.Bind(ctx, goodA, "4600000000017", ""); err != nil {
		t.Fatalf("Bind A: %v", err)
	}
	// Тот же ШК на другой товар → конфликт, привязка A не тронута.
	if err := svc.Bind(ctx, goodB, "4600000000017", ""); !errors.Is(err, repository.ErrBarcodeConflict) {
		t.Fatalf("ожидалась repository.ErrBarcodeConflict (→409), получено %v", err)
	}
	got, err := svc.ResolveGood(ctx, "4600000000017")
	if err != nil || got.ID != goodA {
		t.Fatalf("после конфликта ШК должен остаться за A: id=%s err=%v", got.ID, err)
	}
}

// TestBarcode_bindMissingGood_notFound — привязка к несуществующему товару → ErrGoodNotFound (→404).
func TestBarcode_bindMissingGood_notFound(t *testing.T) {
	pool := testutil.StartPostgres(t)
	svc := newBarcodeSvc(pool)

	missing := "00000000-0000-0000-0000-0000000000ff"
	err := svc.Bind(context.Background(), missing, "4600000000017", "")
	if !errors.Is(err, repository.ErrGoodNotFound) {
		t.Fatalf("ожидалась repository.ErrGoodNotFound (→404), получено %v", err)
	}
}

// TestBarcode_validation — пустые good_id/barcode отклоняются (→400), репозиторий не трогается.
func TestBarcode_validation(t *testing.T) {
	svc := service.NewBarcodeService(nil) // валидация до репозитория, БД не нужна
	ctx := context.Background()

	if err := svc.Bind(ctx, "", "123", ""); !errors.Is(err, service.ErrEmptyGoodID) {
		t.Fatalf("пустой good_id: ожидалась ErrEmptyGoodID, получено %v", err)
	}
	if err := svc.Bind(ctx, "g", "  ", ""); !errors.Is(err, service.ErrEmptyBarcode) {
		t.Fatalf("пустой barcode: ожидалась ErrEmptyBarcode, получено %v", err)
	}
	if _, err := svc.ResolveGood(ctx, "   "); !errors.Is(err, service.ErrEmptyBarcode) {
		t.Fatalf("пустой код резолва: ожидалась ErrEmptyBarcode, получено %v", err)
	}
}
