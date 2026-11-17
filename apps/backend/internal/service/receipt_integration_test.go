package service_test

import (
	"context"
	"errors"
	"testing"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/shopspring/decimal"

	"craftwms/internal/model"
	"craftwms/internal/repository"
	"craftwms/internal/service"
	"craftwms/internal/testutil"
)

// Домен приёмки (P4-02): документ живёт по статусам, оприходование ДОБАВЛЯЕТ к остатку.
// Отличие от ввода остатков принципиально: тот фиксирует факт («в ячейке лежит столько»),
// а приёмка приращивает, поэтому повтор здесь опасен и закрыт статусом.

type rcEnv struct {
	pool        *pgxpool.Pool
	svc         *service.ReceiptService
	stockRepo   *repository.StockRepository
	warehouse   string
	cell1       string
	cell2       string
	cellDefault string
	good        string
	supplier    string
	user        string
	iwh         string
}

func setupReceipt(t *testing.T) *rcEnv {
	t.Helper()
	pool := testutil.StartPostgres(t)
	ctx := context.Background()
	e := &rcEnv{
		pool:      pool,
		svc:       service.NewReceiptService(repository.NewReceiptRepository(pool), repository.NewCellRepository(pool)),
		stockRepo: repository.NewStockRepository(pool),
	}
	scan := func(sql string, args ...any) string {
		var id string
		if err := pool.QueryRow(ctx, sql, args...).Scan(&id); err != nil {
			t.Fatalf("seed %q: %v", sql, err)
		}
		return id
	}
	e.warehouse = scan(`INSERT INTO warehouses (code,name) VALUES ('SHB','Шабулина') RETURNING id::text`)
	e.cell1 = scan(`INSERT INTO cells (warehouse_id,address) VALUES ($1::uuid,'M1-1-1-1') RETURNING id::text`, e.warehouse)
	e.cell2 = scan(`INSERT INTO cells (warehouse_id,address) VALUES ($1::uuid,'M1-1-2-1') RETURNING id::text`, e.warehouse)
	// Дефолтная ячейка склада - её подставляет приёмка, когда кладовщик место не выбирал (P4-03).
	// Заводится так же, как в бою: через тот же метод репозитория, что зовут сидер и импорт ячеек.
	e.cellDefault = mustEnsureDefaultCell(t, pool, e.warehouse)
	e.good = scan(`INSERT INTO goods (name,uom) VALUES ('Кальмар','шт') RETURNING id::text`)
	e.supplier = scan(`INSERT INTO suppliers (name) VALUES ('Поставщик') RETURNING id::text`)
	e.user = scan(`INSERT INTO users (login,password_hash,full_name) VALUES ('90000031','x','Кладовщик') RETURNING id::text`)
	e.iwh = scan(`SELECT id::text FROM internal_warehouses WHERE is_default`)
	return e
}

// qty читает остаток на складе по умолчанию - туда приходует приёмка.
func (e *rcEnv) qty(t *testing.T, cell, batch string) decimal.Decimal {
	t.Helper()
	q, err := e.stockRepo.GetQty(context.Background(), model.StockKey{
		CellID: cell, GoodID: e.good, BatchID: batch, InternalWarehouseID: e.iwh,
	})
	if err != nil {
		t.Fatalf("GetQty: %v", err)
	}
	return q
}

func (e *rcEnv) batchOf(t *testing.T, iso string) string {
	t.Helper()
	var id string
	if err := e.pool.QueryRow(context.Background(),
		`SELECT id::text FROM batches WHERE good_id = $1::uuid AND production_date = $2::date`,
		e.good, iso).Scan(&id); err != nil {
		t.Fatalf("партия %s: %v", iso, err)
	}
	return id
}

// mustEnsureDefaultCell заводит складу дефолтную ячейку тем же методом, что зовут сидер и импорт.
func mustEnsureDefaultCell(t *testing.T, pool *pgxpool.Pool, warehouseID string) string {
	t.Helper()
	var id string
	err := repository.WithinTx(context.Background(), pool, func(q repository.Querier) error {
		var err error
		id, err = repository.NewCellRepository(pool).EnsureDefault(context.Background(), q, warehouseID)
		return err
	})
	if err != nil {
		t.Fatalf("дефолтная ячейка: %v", err)
	}
	return id
}

// Ячейку кладовщик на приёмке не выбирает: пустая ячейка в строке - это просьба подставить
// дефолтную, а не ошибка ввода. Проверяем и подстановку, и что вернулась именно она:
// умолчание, работающее вслепую, кладовщик не смог бы отличить от промаха.
func TestReceipt_defaultCellSubstituted(t *testing.T) {
	e := setupReceipt(t)
	ctx := context.Background()
	id := uuid.NewString()

	if err := e.svc.Start(ctx, id, e.warehouse, "", e.user, "ТН-1", "01-10-2026"); err != nil {
		t.Fatalf("Start: %v", err)
	}
	cell, err := e.svc.AddLine(ctx, id, e.good, "15-01-2026", "", "", decimal.RequireFromString("7"))
	if err != nil {
		t.Fatalf("AddLine без ячейки: %v", err)
	}
	if cell != e.cellDefault {
		t.Fatalf("подставлена ячейка %s, ожидалась дефолтная %s", cell, e.cellDefault)
	}

	// Ячейку ищем по флагу, а не по строке адреса, - но адрес обязан быть тем, о котором
	// договорились с заказчиком: по нему кладовщик находит место на складе.
	var address string
	if err := e.pool.QueryRow(ctx,
		`SELECT address FROM cells WHERE id = $1::uuid`, cell).Scan(&address); err != nil {
		t.Fatalf("адрес дефолтной ячейки: %v", err)
	}
	if address != model.DefaultCellAddress {
		t.Errorf("адрес дефолтной ячейки %q, ожидался %q", address, model.DefaultCellAddress)
	}

	if _, err := e.svc.Post(ctx, id); err != nil {
		t.Fatalf("Post: %v", err)
	}
	if got := e.qty(t, e.cellDefault, e.batchOf(t, "2026-01-15")); !got.Equal(decimal.RequireFromString("7")) {
		t.Errorf("остаток в дефолтной ячейке: %s, ожидалось 7", got)
	}
}

// Критерий задачи: документ проходит по статусам, и оприходование поднимает остаток.
func TestReceipt_lifecycle(t *testing.T) {
	e := setupReceipt(t)
	ctx := context.Background()
	id := uuid.NewString()

	if err := e.svc.Start(ctx, id, e.warehouse, e.supplier, e.user, "ТН-1", "01-10-2026"); err != nil {
		t.Fatalf("Start: %v", err)
	}
	rc, _, err := e.svc.Get(ctx, id)
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if rc.Status != model.ReceiptDraft || rc.PostedAt != nil {
		t.Fatalf("свежий документ: статус=%s posted_at=%v", rc.Status, rc.PostedAt)
	}

	if _, err := e.svc.AddLine(ctx, id, e.good, "15-01-2026", e.cell1, "", decimal.RequireFromString("10")); err != nil {
		t.Fatalf("AddLine: %v", err)
	}
	batch := e.batchOf(t, "2026-01-15")

	// До оприходования остаток не двигается: документ-черновик ещё ничего не значит для учёта.
	if got := e.qty(t, e.cell1, batch); !got.IsZero() {
		t.Fatalf("остаток до оприходования: %s, ожидался 0", got)
	}

	n, err := e.svc.Post(ctx, id)
	if err != nil {
		t.Fatalf("Post: %v", err)
	}
	if n != 1 {
		t.Errorf("проведено строк: %d, ожидалась 1", n)
	}
	if got := e.qty(t, e.cell1, batch); !got.Equal(decimal.RequireFromString("10")) {
		t.Errorf("остаток после оприходования: %s, ожидался 10", got)
	}

	rc, _, _ = e.svc.Get(ctx, id)
	if rc.Status != model.ReceiptPosted || rc.PostedAt == nil {
		t.Errorf("после оприходования: статус=%s posted_at=%v", rc.Status, rc.PostedAt)
	}
}

// Оприходование ПРИРАЩИВАЕТ, поэтому повтор обязан упереться в статус: иначе он удвоил бы приход.
// Это главное отличие приёмки от ввода остатков, где повтор безвреден по построению.
func TestReceipt_postIsNotRepeatable(t *testing.T) {
	e := setupReceipt(t)
	ctx := context.Background()
	id := uuid.NewString()

	if err := e.svc.Start(ctx, id, e.warehouse, "", e.user, "ТН-1", "01-10-2026"); err != nil {
		t.Fatalf("Start: %v", err)
	}
	if _, err := e.svc.AddLine(ctx, id, e.good, "15-01-2026", e.cell1, "", decimal.RequireFromString("4")); err != nil {
		t.Fatalf("AddLine: %v", err)
	}
	if _, err := e.svc.Post(ctx, id); err != nil {
		t.Fatalf("первое оприходование: %v", err)
	}
	if _, err := e.svc.Post(ctx, id); !errors.Is(err, model.ErrReceiptPosted) {
		t.Fatalf("повтор: ожидалась ErrReceiptPosted, получено %v", err)
	}

	batch := e.batchOf(t, "2026-01-15")
	if got := e.qty(t, e.cell1, batch); !got.Equal(decimal.RequireFromString("4")) {
		t.Errorf("повтор удвоил приход: остаток %s, ожидался 4", got)
	}

	// Оприходованный документ не пополняется: строки уже превратились в остаток.
	if _, err := e.svc.AddLine(ctx, id, e.good, "15-01-2026", e.cell1, "", decimal.RequireFromString("1")); !errors.Is(err, model.ErrReceiptPosted) {
		t.Errorf("строка в проведённый документ: ожидалась ErrReceiptPosted, получено %v", err)
	}
}

// Повторный скан той же позиции увеличивает количество в строке, а не плодит строки.
// Грань включает ячейку и ГЕ, поэтому та же позиция в другую ячейку - отдельная строка.
func TestReceipt_lineGrain(t *testing.T) {
	e := setupReceipt(t)
	ctx := context.Background()
	id := uuid.NewString()
	if err := e.svc.Start(ctx, id, e.warehouse, "", e.user, "ТН-1", "01-10-2026"); err != nil {
		t.Fatalf("Start: %v", err)
	}

	add := func(cell string, qty string) {
		t.Helper()
		if _, err := e.svc.AddLine(ctx, id, e.good, "15-01-2026", cell, "", decimal.RequireFromString(qty)); err != nil {
			t.Fatalf("AddLine: %v", err)
		}
	}
	add(e.cell1, "3")
	add(e.cell1, "2") // тот же товар, партия и ячейка - в ту же строку
	add(e.cell2, "5") // другая ячейка - отдельная строка

	_, lines, err := e.svc.Get(ctx, id)
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if len(lines) != 2 {
		t.Fatalf("строк в документе: %d, ожидались 2", len(lines))
	}
	byCell := map[string]decimal.Decimal{}
	for _, ln := range lines {
		byCell[ln.CellAddress] = ln.Qty
	}
	if got := byCell["M1-1-1-1"]; !got.Equal(decimal.RequireFromString("5")) {
		t.Errorf("повторный скан не сложился: %s, ожидалось 5", got)
	}
	if got := byCell["M1-1-2-1"]; !got.Equal(decimal.RequireFromString("5")) {
		t.Errorf("вторая ячейка: %s, ожидалось 5", got)
	}
	// Наименование товара приходит вместе со строкой - экрану не нужен второй запрос.
	if lines[0].GoodName != "Кальмар" {
		t.Errorf("наименование в строке: %q", lines[0].GoodName)
	}
}

// Приёмка в грузовую единицу: состав ГЕ пополняется, сама ГЕ уезжает в ячейку и считается
// размещённой. Остаток при этом поднимается так же, как у россыпи, - ГЕ его не заменяет.
func TestReceipt_intoLoadUnit(t *testing.T) {
	e := setupReceipt(t)
	ctx := context.Background()
	id := uuid.NewString()
	lu := uuid.NewString()
	if _, err := e.pool.Exec(ctx, `INSERT INTO load_units (id, kind) VALUES ($1::uuid,'box')`, lu); err != nil {
		t.Fatalf("создать ГЕ: %v", err)
	}
	if err := e.svc.Start(ctx, id, e.warehouse, "", e.user, "ТН-1", "01-10-2026"); err != nil {
		t.Fatalf("Start: %v", err)
	}
	if _, err := e.svc.AddLine(ctx, id, e.good, "15-01-2026", e.cell1, lu, decimal.RequireFromString("6")); err != nil {
		t.Fatalf("AddLine: %v", err)
	}
	if _, err := e.svc.Post(ctx, id); err != nil {
		t.Fatalf("Post: %v", err)
	}

	batch := e.batchOf(t, "2026-01-15")
	if got := e.qty(t, e.cell1, batch); !got.Equal(decimal.RequireFromString("6")) {
		t.Errorf("остаток по ГЕ-строке: %s, ожидался 6", got)
	}

	var content, status string
	var cell *string
	if err := e.pool.QueryRow(ctx, `
		SELECT c.qty::text, u.status, u.cell_id::text
		FROM load_units u JOIN lu_content c ON c.load_unit_id = u.id
		WHERE u.id = $1::uuid`, lu).Scan(&content, &status, &cell); err != nil {
		t.Fatalf("состав ГЕ: %v", err)
	}
	if content != "6.000" || status != "placed" || cell == nil || *cell != e.cell1 {
		t.Errorf("ГЕ после приёмки: состав=%s статус=%s ячейка=%v", content, status, cell)
	}
}

// Короб не может лежать в двух местах: противоречивый документ не проводится целиком,
// а не «как-нибудь» - молчаливый выбор одной из ячеек соврал бы про место хранения.
func TestReceipt_loadUnitCellConflict(t *testing.T) {
	e := setupReceipt(t)
	ctx := context.Background()
	id := uuid.NewString()
	lu := uuid.NewString()
	if _, err := e.pool.Exec(ctx, `INSERT INTO load_units (id, kind) VALUES ($1::uuid,'box')`, lu); err != nil {
		t.Fatalf("создать ГЕ: %v", err)
	}
	if err := e.svc.Start(ctx, id, e.warehouse, "", e.user, "ТН-1", "01-10-2026"); err != nil {
		t.Fatalf("Start: %v", err)
	}
	if _, err := e.svc.AddLine(ctx, id, e.good, "15-01-2026", e.cell1, lu, decimal.RequireFromString("1")); err != nil {
		t.Fatalf("AddLine 1: %v", err)
	}
	if _, err := e.svc.AddLine(ctx, id, e.good, "16-01-2026", e.cell2, lu, decimal.RequireFromString("1")); err != nil {
		t.Fatalf("AddLine 2: %v", err)
	}

	if _, err := e.svc.Post(ctx, id); !errors.Is(err, model.ErrLoadUnitCellConflict) {
		t.Fatalf("ожидалась ErrLoadUnitCellConflict, получено %v", err)
	}
	// Транзакция откатилась целиком: ни остатка, ни смены статуса.
	batch := e.batchOf(t, "2026-01-15")
	if got := e.qty(t, e.cell1, batch); !got.IsZero() {
		t.Errorf("частично проведённый остаток: %s, ожидался 0", got)
	}
	rc, _, _ := e.svc.Get(ctx, id)
	if rc.Status != model.ReceiptDraft {
		t.Errorf("статус после неудачного оприходования: %s, ожидался draft", rc.Status)
	}
}

// Границы: пустой документ проводить нечего, валидация ловит незаполненное.
func TestReceipt_guards(t *testing.T) {
	e := setupReceipt(t)
	ctx := context.Background()
	id := uuid.NewString()
	if err := e.svc.Start(ctx, id, e.warehouse, "", e.user, "ТН-1", "01-10-2026"); err != nil {
		t.Fatalf("Start: %v", err)
	}

	if _, err := e.svc.Post(ctx, id); !errors.Is(err, model.ErrEmptyReceipt) {
		t.Errorf("пустой документ: ожидалась ErrEmptyReceipt, получено %v", err)
	}
	if err := e.svc.Start(ctx, "", e.warehouse, "", e.user, "ТН-1", "01-10-2026"); !errors.Is(err, model.ErrEmptyReceiptID) {
		t.Errorf("без id: %v", err)
	}
	if err := e.svc.Start(ctx, uuid.NewString(), "", "", e.user, "ТН-1", "01-10-2026"); !errors.Is(err, model.ErrEmptyWarehouse) {
		t.Errorf("без склада: %v", err)
	}
	if _, err := e.svc.AddLine(ctx, id, "", "15-01-2026", e.cell1, "", decimal.NewFromInt(1)); !errors.Is(err, model.ErrEmptyGoodID) {
		t.Errorf("без товара: %v", err)
	}
	if _, err := e.svc.AddLine(ctx, id, e.good, "15-01-2026", e.cell1, "", decimal.Zero); !errors.Is(err, model.ErrInvalidQuantity) {
		t.Errorf("нулевое количество: %v", err)
	}
	if _, err := e.svc.AddLine(ctx, id, e.good, "2026-01-15", e.cell1, "", decimal.NewFromInt(1)); !errors.Is(err, model.ErrInvalidDate) {
		t.Errorf("дата в ISO вместо DD-MM-YYYY: %v", err)
	}
	if _, err := e.svc.Post(ctx, uuid.NewString()); !errors.Is(err, model.ErrReceiptNotFound) {
		t.Errorf("несуществующий документ: %v", err)
	}
}
