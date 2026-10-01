package service_test

import (
	"context"
	"errors"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"

	"craftwms/internal/barcode"
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

// TestBarcode_listByGood — секция «Штрихкоды» карточки: все ШК товара, сортировка, пустой список.
func TestBarcode_listByGood(t *testing.T) {
	pool := testutil.StartPostgres(t)
	svc := newBarcodeSvc(pool)
	ctx := context.Background()

	goodA := seedGood(t, pool, "Товар A")
	goodB := seedGood(t, pool, "Товар B")

	// Товар без ШК → пустой список (не nil → JSON `[]`).
	empty, err := svc.ListByGood(ctx, goodA)
	if err != nil {
		t.Fatalf("ListByGood (пусто): %v", err)
	}
	if empty == nil || len(empty) != 0 {
		t.Fatalf("ожидался пустой не-nil список, получено %#v", empty)
	}

	// Два ШК товару A + один товару B (не должен попасть в выборку A).
	if err := svc.Bind(ctx, goodA, "4600000000024", "ean13"); err != nil {
		t.Fatalf("Bind A#2: %v", err)
	}
	if err := svc.Bind(ctx, goodA, "4600000000017", ""); err != nil {
		t.Fatalf("Bind A#1: %v", err)
	}
	if err := svc.Bind(ctx, goodB, "4600000000031", ""); err != nil {
		t.Fatalf("Bind B: %v", err)
	}

	list, err := svc.ListByGood(ctx, goodA)
	if err != nil {
		t.Fatalf("ListByGood: %v", err)
	}
	if len(list) != 2 {
		t.Fatalf("ожидалось 2 ШК у товара A, получено %d", len(list))
	}
	// Сортировка по строке ШК: ...017 раньше ...024.
	if list[0].Barcode != "4600000000017" || list[1].Barcode != "4600000000024" {
		t.Fatalf("ожидалась сортировка по ШК, получено %s,%s", list[0].Barcode, list[1].Barcode)
	}
	// symbology: у первого пусто (NULL), у второго 'ean13'.
	if list[0].Symbology != nil {
		t.Fatalf("ожидался NULL symbology у ...017, получено %v", *list[0].Symbology)
	}
	if list[1].Symbology == nil || *list[1].Symbology != "ean13" {
		t.Fatalf("ожидался ean13 у ...024, получено %v", list[1].Symbology)
	}
}

// TestBarcode_unbind — отвязка: резолв после отвязки 404; идемпотентность; перепривязка на другой
// товар после отвязки; отвязка одного ШК не трогает остальные.
func TestBarcode_unbind(t *testing.T) {
	pool := testutil.StartPostgres(t)
	svc := newBarcodeSvc(pool)
	ctx := context.Background()

	goodA := seedGood(t, pool, "Товар A")
	goodB := seedGood(t, pool, "Товар B")

	// Привязали два ШК товару A.
	if err := svc.Bind(ctx, goodA, "4600000000017", ""); err != nil {
		t.Fatalf("Bind A#1: %v", err)
	}
	if err := svc.Bind(ctx, goodA, "4600000000024", ""); err != nil {
		t.Fatalf("Bind A#2: %v", err)
	}

	// Отвязали первый → резолвится 404, второй жив.
	if err := svc.Unbind(ctx, "4600000000017"); err != nil {
		t.Fatalf("Unbind: %v", err)
	}
	if _, err := svc.ResolveGood(ctx, "4600000000017"); !errors.Is(err, repository.ErrNotFound) {
		t.Fatalf("после отвязки ожидался ErrNotFound, получено %v", err)
	}
	if got, err := svc.ResolveGood(ctx, "4600000000024"); err != nil || got.ID != goodA {
		t.Fatalf("второй ШК должен остаться за A: id=%s err=%v", got.ID, err)
	}

	// Идемпотентность: повторная отвязка того же (уже отсутствующего) ШК — не ошибка.
	if err := svc.Unbind(ctx, "4600000000017"); err != nil {
		t.Fatalf("повторная отвязка должна быть идемпотентной, получено %v", err)
	}

	// Перепривязка = отвязка + привязка на другой товар: раньше был бы конфликт, теперь ок.
	if err := svc.Bind(ctx, goodB, "4600000000017", ""); err != nil {
		t.Fatalf("перепривязка на B после отвязки: %v", err)
	}
	if got, err := svc.ResolveGood(ctx, "4600000000017"); err != nil || got.ID != goodB {
		t.Fatalf("после перепривязки ШК должен вести на B: id=%s err=%v", got.ID, err)
	}
}

// TestBarcode_unbind_validation — пустой ШК отклоняется (→400), репозиторий не трогается.
func TestBarcode_unbind_validation(t *testing.T) {
	svc := service.NewBarcodeService(nil) // валидация до репозитория, БД не нужна
	if err := svc.Unbind(context.Background(), "   "); !errors.Is(err, service.ErrEmptyBarcode) {
		t.Fatalf("пустой ШК: ожидалась ErrEmptyBarcode, получено %v", err)
	}
	if _, err := svc.ListByGood(context.Background(), "  "); !errors.Is(err, service.ErrEmptyGoodID) {
		t.Fatalf("пустой good_id: ожидалась ErrEmptyGoodID, получено %v", err)
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

// TestBarcode_listAll — выгрузка всех привязок ШК для офлайн-кэша устройства (P2-02).
//
// Проверяет то, ради чего эндпоинт и появился: справочник забирается страницами, а не обходом
// товаров по одному запросу; в каждой записи есть товар, иначе по коду нечего резолвить.
func TestBarcode_listAll(t *testing.T) {
	pool := testutil.StartPostgres(t)
	svc := newBarcodeSvc(pool)
	ctx := context.Background()

	goodA := seedGood(t, pool, "Товар A")
	goodB := seedGood(t, pool, "Товар B")

	// Два ШК на один товар (штука и короб, P-FS-11) и один на другой.
	for _, b := range []struct{ good, code, sym string }{
		{goodA, "4600000000011", "ean13"},
		{goodA, "BOX-A-0001", "code128"},
		{goodB, "4600000000028", "ean13"},
	} {
		if err := svc.Bind(ctx, b.good, b.code, b.sym); err != nil {
			t.Fatalf("Bind %q: %v", b.code, err)
		}
	}

	page, err := svc.List(ctx, 0, 0)
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if page.Total != 3 || len(page.Items) != 3 {
		t.Fatalf("ожидалось 3 привязки, получено total=%d items=%d", page.Total, len(page.Items))
	}

	// У каждой записи должен быть товар: без good_id кэш не сможет резолвить скан.
	byCode := map[string]string{}
	for _, it := range page.Items {
		if it.GoodID == "" {
			t.Fatalf("привязка %q без good_id", it.Barcode)
		}
		byCode[it.Barcode] = it.GoodID
	}
	if byCode["4600000000011"] != goodA || byCode["BOX-A-0001"] != goodA {
		t.Fatalf("оба ШК товара A должны указывать на него: %v", byCode)
	}
	if byCode["4600000000028"] != goodB {
		t.Fatalf("ШК товара B указывает не туда: %v", byCode)
	}

	// Страницы не перемешиваются: порядок по ШК стабилен, total считается по всей выборке.
	first, err := svc.List(ctx, 2, 0)
	if err != nil {
		t.Fatalf("List(2,0): %v", err)
	}
	second, err := svc.List(ctx, 2, 2)
	if err != nil {
		t.Fatalf("List(2,2): %v", err)
	}
	if len(first.Items) != 2 || len(second.Items) != 1 {
		t.Fatalf("страницы: ожидалось 2+1, получено %d+%d", len(first.Items), len(second.Items))
	}
	if first.Total != 3 || second.Total != 3 {
		t.Fatalf("total должен считаться по всей выборке, получено %d и %d", first.Total, second.Total)
	}
	if first.Items[0].Barcode > first.Items[1].Barcode {
		t.Fatalf("порядок по ШК нарушен: %v", first.Items)
	}
}

// Внутренний ШК для товара без штрихкода (P4-07): генерация, идемпотентность, уникальность.
func TestBarcode_generateInternal(t *testing.T) {
	pool := testutil.StartPostgres(t)
	svc := newBarcodeSvc(pool)
	ctx := context.Background()

	good := seedGood(t, pool, "Товар без ШК")

	code, created, err := svc.GenerateInternal(ctx, good)
	if err != nil {
		t.Fatalf("GenerateInternal: %v", err)
	}
	if !created {
		t.Error("первая выдача обязана сообщить, что код создан")
	}
	if !barcode.IsInternalEAN13(code) {
		t.Fatalf("выдан код %q — не внутренний EAN-13", code)
	}

	// Критерий задачи: выданный код читается как товар — то есть резолвится обратно.
	resolved, err := svc.ResolveGood(ctx, code)
	if err != nil {
		t.Fatalf("ResolveGood(%s): %v", code, err)
	}
	if resolved.ID != good {
		t.Errorf("код резолвится в товар %s, ожидался %s", resolved.ID, good)
	}
}

// Повторный вызов отдаёт ТОТ ЖЕ код, а не заводит второй.
//
// Иначе повторное нажатие (связь мигнула, кладовщик не увидел ответа) дало бы товару два кода,
// из которых на упаковке наклеен один, — и второй жил бы в справочнике мусором.
func TestBarcode_generateInternalIsIdempotent(t *testing.T) {
	pool := testutil.StartPostgres(t)
	svc := newBarcodeSvc(pool)
	ctx := context.Background()

	good := seedGood(t, pool, "Товар без ШК")

	first, created, err := svc.GenerateInternal(ctx, good)
	if err != nil || !created {
		t.Fatalf("первая выдача: %v, created=%v", err, created)
	}
	second, createdAgain, err := svc.GenerateInternal(ctx, good)
	if err != nil {
		t.Fatalf("повтор: %v", err)
	}
	if second != first {
		t.Errorf("повтор выдал другой код: %s вместо %s", second, first)
	}
	if createdAgain {
		t.Error("повтор сообщил о создании, хотя код уже был")
	}

	var count int
	if err := pool.QueryRow(ctx,
		`SELECT count(*) FROM barcodes WHERE good_id = $1::uuid AND is_internal`,
		good).Scan(&count); err != nil {
		t.Fatal(err)
	}
	if count != 1 {
		t.Errorf("внутренних ШК у товара: %d, ожидался 1", count)
	}
}

// Разным товарам достаются разные коды, и внутренний код встаёт рядом с внешним, не вытесняя его.
func TestBarcode_generateInternalUniqueAndAdditive(t *testing.T) {
	pool := testutil.StartPostgres(t)
	svc := newBarcodeSvc(pool)
	ctx := context.Background()

	codes := make(map[string]string)
	for i := range 20 {
		good := seedGood(t, pool, "Товар")
		code, _, err := svc.GenerateInternal(ctx, good)
		if err != nil {
			t.Fatalf("выдача %d: %v", i, err)
		}
		if prev, dup := codes[code]; dup {
			t.Fatalf("код %s выдан дважды: товарам %s и %s", code, prev, good)
		}
		codes[code] = good
	}

	// Аддитивность: у товара может быть и свой ШК с упаковки, и наш.
	good := seedGood(t, pool, "Товар со своим ШК")
	if err := svc.Bind(ctx, good, "4600000000116", "ean13"); err != nil {
		t.Fatalf("Bind: %v", err)
	}
	internal, _, err := svc.GenerateInternal(ctx, good)
	if err != nil {
		t.Fatalf("GenerateInternal: %v", err)
	}
	list, err := svc.ListByGood(ctx, good)
	if err != nil {
		t.Fatalf("ListByGood: %v", err)
	}
	if len(list) != 2 {
		t.Fatalf("ШК у товара: %d, ожидалось 2 (внешний и внутренний)", len(list))
	}
	// Оба кода резолвятся в один товар.
	for _, code := range []string{"4600000000116", internal} {
		got, err := svc.ResolveGood(ctx, code)
		if err != nil || got.ID != good {
			t.Errorf("код %s резолвится неверно: %v, %s", code, err, got.ID)
		}
	}
}

// Код, уже занятый ВНЕШНЕЙ привязкой, не ломает выдачу: берётся следующий номер.
//
// Выгрузка 1С может принести внутренний код прежней системы с тем же префиксом — тогда наш
// генератор однажды дойдёт до него.
func TestBarcode_generateInternalSkipsTakenCode(t *testing.T) {
	pool := testutil.StartPostgres(t)
	svc := newBarcodeSvc(pool)
	ctx := context.Background()

	// Занимаем код, который генератор выдаст следующим.
	var next int64
	if err := pool.QueryRow(ctx, `SELECT last_value FROM internal_barcode_serial`).Scan(&next); err != nil {
		t.Fatal(err)
	}
	taken, err := barcode.Internal(barcode.InternalPrefix, next)
	if err != nil {
		t.Fatal(err)
	}
	stranger := seedGood(t, pool, "Чужой товар из выгрузки")
	if err := svc.Bind(ctx, stranger, taken, "ean13"); err != nil {
		t.Fatalf("Bind занятого кода: %v", err)
	}

	good := seedGood(t, pool, "Товар без ШК")
	code, _, err := svc.GenerateInternal(ctx, good)
	if err != nil {
		t.Fatalf("GenerateInternal: %v", err)
	}
	if code == taken {
		t.Fatalf("выдан уже занятый код %s", code)
	}
	if !barcode.IsInternalEAN13(code) {
		t.Errorf("выдан код %q — не внутренний EAN-13", code)
	}
}

// Несуществующий товар — отказ, а не битая привязка.
func TestBarcode_generateInternalUnknownGood(t *testing.T) {
	pool := testutil.StartPostgres(t)
	svc := newBarcodeSvc(pool)

	_, _, err := svc.GenerateInternal(context.Background(),
		"00000000-0000-4000-8000-000000000000")
	if !errors.Is(err, repository.ErrGoodNotFound) {
		t.Errorf("неизвестный товар: ожидалась ErrGoodNotFound, получено %v", err)
	}
}
