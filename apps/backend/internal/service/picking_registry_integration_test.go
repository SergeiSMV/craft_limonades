package service_test

import (
	"context"
	"os"
	"testing"

	"craftwms/internal/repository"
	"craftwms/internal/service"
	"craftwms/internal/testutil"
)

// TestPickingRegistry_sampleAgainstCatalog — образец реестра 1С против живого справочника:
// код «00-00001101» находит товар «00000001101», признак «маркируемый» доезжает до строки,
// коды, которых нет в справочнике, попадают в отчёт и помечают заказ.
func TestPickingRegistry_sampleAgainstCatalog(t *testing.T) {
	pool := testutil.StartPostgres(t)
	ctx := context.Background()
	if _, err := pool.Exec(ctx, `
		INSERT INTO goods (code, name, uom, cz_marked) VALUES
			('00000001101', 'Сыр вьетнамский', 'шт', false),
			('00000001102', 'Сыр пармезан', 'шт', true)`); err != nil {
		t.Fatalf("завести товары: %v", err)
	}

	f, err := os.Open("../../../../docs/1c/Реестр_2026-10-21_1530.xlsx")
	if err != nil {
		t.Fatalf("открыть образец: %v", err)
	}
	defer func() { _ = f.Close() }()
	got, err := service.NewPickingRegistryService(repository.NewGoodsRepository(pool)).Parse(ctx, f)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if len(got.Orders) != 2 || len(got.Errors) != 0 {
		t.Fatalf("заказов %d (ждали 2), ошибок %+v", len(got.Orders), got.Errors)
	}
	first := got.Orders[0].Lines
	if first[0].Good == nil || first[0].Good.Name != "Сыр вьетнамский" || first[0].Good.CZMarked {
		t.Errorf("строка 00-00001101: %+v", first[0].Good)
	}
	if first[1].Good == nil || !first[1].Good.CZMarked {
		t.Errorf("строка 00-00001102 - маркируемый: %+v", first[1].Good)
	}
	for _, code := range got.UnknownCodes {
		if code == "00000001101" || code == "00000001102" {
			t.Errorf("заведённый код %s в нераспознанных", code)
		}
	}
	if len(got.UnknownCodes) == 0 || !got.Orders[0].HasUnknown {
		t.Errorf("в образце есть коды вне справочника: %v, пометка %v", got.UnknownCodes, got.Orders[0].HasUnknown)
	}
}
