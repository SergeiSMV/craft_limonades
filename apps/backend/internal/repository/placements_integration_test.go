package repository_test

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/shopspring/decimal"

	"craftwms/internal/model"
	"craftwms/internal/repository"
	"craftwms/migrations"
)

// Тесты P5-01: журнал размещений ГЕ. Критерий задачи - видно текущее место ГЕ и её историю;
// инвариант - текущее место (`load_units.cell_id`) равно `to_cell_id` последней строки журнала.
// Фикстура setupStock - из stock_integration_test.go, newLU - из load_units_integration_test.go.

// newUser заводит кладовщика и возвращает его id.
func newUser(t *testing.T, fx *stockFixture) string {
	t.Helper()
	var id string
	mustScan(t, fx.pool, `INSERT INTO users (login, password_hash, full_name,position_id)
		VALUES ('90000077','x','Кладовщик','7a000000-0000-4000-8000-000000000002') RETURNING id::text`, &id)
	return id
}

// testDoc - накладная поставщика тестовых приёмок (ADHOC-23).
var testDoc = model.SupplierDoc{Number: "ТН-1", Date: time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC)}

// receiveBox принимает короб с товаром в ячейку и оприходует приёмку - так ГЕ появляется
// на складе в жизни.
func receiveBox(t *testing.T, fx *stockFixture, user, lu, cell string) string {
	t.Helper()
	ctx := context.Background()
	repo := repository.NewReceiptRepository(fx.pool)
	var wh string
	mustScan(t, fx.pool, `SELECT warehouse_id::text FROM cells WHERE id = $1::uuid`, &wh, cell)
	receipt := uuid.NewString()
	mustNoErr(t, repo.Create(ctx, receipt, wh, "", user, testDoc))
	mustNoErr(t, repo.AddLine(ctx, receipt, model.ReceiptLineInput{
		GoodID: fx.good, ProductionDate: "2026-01-01", CellID: cell, LoadUnitID: lu,
		Qty: decimal.NewFromInt(12),
	}))
	if _, err := repo.Post(ctx, receipt); err != nil {
		t.Fatalf("оприходовать приёмку: %v", err)
	}
	return receipt
}

// currentCell - текущее место ГЕ по шапке.
func currentCell(t *testing.T, fx *stockFixture, lu string) string {
	t.Helper()
	got, err := repository.NewLoadUnitRepository(fx.pool).ByID(context.Background(), lu)
	if err != nil || got.CellID == nil {
		t.Fatalf("место ГЕ: %v, cell=%v", err, got.CellID)
	}
	return *got.CellID
}

// Приёмка - первое размещение: строка журнала «ниоткуда → в ячейку» с автором и документом.
func TestPlacements_receiptWritesFirstRow(t *testing.T) {
	fx := setupStock(t)
	user := newUser(t, fx)
	lu := newLU(t, fx, model.LoadUnitBox)

	receipt := receiveBox(t, fx, user, lu, fx.cellA)

	hist, err := repository.NewLoadUnitRepository(fx.pool).Placements(context.Background(), lu)
	mustNoErr(t, err)
	if len(hist) != 1 {
		t.Fatalf("строк истории: %d, ожидалась 1", len(hist))
	}
	p := hist[0]
	if p.FromCellID != nil || p.ToCellID != fx.cellA || p.ToAddress != "A" {
		t.Errorf("перенос: from=%v to=%s (%s), ожидалось ниоткуда → A", p.FromCellID, p.ToCellID, p.ToAddress)
	}
	if p.Source != model.PlacementReceipt || p.ReceiptID == nil || *p.ReceiptID != receipt {
		t.Errorf("источник: %s, документ %v - ожидалась приёмка %s", p.Source, p.ReceiptID, receipt)
	}
	if p.UserID == nil || *p.UserID != user {
		t.Errorf("автор: %v, ожидался кладовщик приёмки", p.UserID)
	}
	if currentCell(t, fx, lu) != fx.cellA {
		t.Errorf("текущее место расходится с журналом")
	}
}

// Перенос пишет «откуда → куда», текущее место следует за последней строкой.
func TestPlacements_moveAppendsHistory(t *testing.T) {
	fx := setupStock(t)
	ctx := context.Background()
	user := newUser(t, fx)
	lu := newLU(t, fx, model.LoadUnitBox)
	receiveBox(t, fx, user, lu, fx.cellA)

	mustNoErr(t, repository.PlaceLoadUnitForTest(ctx, fx.pool, model.PlaceLoadUnitInput{
		LoadUnitID: lu, CellID: fx.cellB, Source: model.PlacementPutaway, UserID: user,
	}))

	hist, err := repository.NewLoadUnitRepository(fx.pool).Placements(ctx, lu)
	mustNoErr(t, err)
	if len(hist) != 2 {
		t.Fatalf("строк истории: %d, ожидалось 2", len(hist))
	}
	last := hist[1]
	if last.FromCellID == nil || *last.FromCellID != fx.cellA || last.FromAddress == nil || *last.FromAddress != "A" {
		t.Errorf("откуда: %v (%v), ожидалась A", last.FromCellID, last.FromAddress)
	}
	if last.ToCellID != fx.cellB || last.Source != model.PlacementPutaway || last.ReceiptID != nil {
		t.Errorf("куда: %s, источник %s, документ %v", last.ToCellID, last.Source, last.ReceiptID)
	}
	if currentCell(t, fx, lu) != last.ToCellID {
		t.Errorf("инвариант нарушен: текущее место не равно последней строке журнала")
	}
}

// Перенос в ту же ячейку - не перенос: журнал не засоряется пустыми строками.
func TestPlacements_sameCellIsNoop(t *testing.T) {
	fx := setupStock(t)
	ctx := context.Background()
	user := newUser(t, fx)
	lu := newLU(t, fx, model.LoadUnitBox)
	receiveBox(t, fx, user, lu, fx.cellA)

	mustNoErr(t, repository.PlaceLoadUnitForTest(ctx, fx.pool, model.PlaceLoadUnitInput{
		LoadUnitID: lu, CellID: fx.cellA, Source: model.PlacementPutaway, UserID: user,
	}))

	hist, err := repository.NewLoadUnitRepository(fx.pool).Placements(ctx, lu)
	mustNoErr(t, err)
	if len(hist) != 1 {
		t.Errorf("строк истории: %d, ожидалась 1 - перенос на месте не пишется", len(hist))
	}
}

// Короб без размещения - пустая история; несуществующий короб - отдельная ошибка.
func TestPlacements_emptyAndUnknown(t *testing.T) {
	fx := setupStock(t)
	ctx := context.Background()
	repo := repository.NewLoadUnitRepository(fx.pool)
	lu := newLU(t, fx, model.LoadUnitBox)

	hist, err := repo.Placements(ctx, lu)
	mustNoErr(t, err)
	if len(hist) != 0 {
		t.Errorf("у неразмещённой ГЕ история: %d строк", len(hist))
	}

	unknown := uuid.NewString()
	if _, err := repo.Placements(ctx, unknown); !errors.Is(err, repository.ErrLoadUnitNotFound) {
		t.Errorf("история неизвестной ГЕ: %v, ожидалась ErrLoadUnitNotFound", err)
	}
	err = repository.PlaceLoadUnitForTest(ctx, fx.pool, model.PlaceLoadUnitInput{
		LoadUnitID: unknown, CellID: fx.cellA, Source: model.PlacementPutaway,
	})
	if !errors.Is(err, repository.ErrLoadUnitNotFound) {
		t.Errorf("размещение неизвестной ГЕ: %v, ожидалась ErrLoadUnitNotFound", err)
	}
}

// Схема не пускает источник, которого нет в наборе, и перенос «на месте» в обход функции.
func TestPlacements_schemaGuards(t *testing.T) {
	fx := setupStock(t)
	ctx := context.Background()
	lu := newLU(t, fx, model.LoadUnitBox)

	if _, err := fx.pool.Exec(ctx, `
		INSERT INTO placements (load_unit_id, to_cell_id, source)
		VALUES ($1::uuid, $2::uuid, 'teleport')`, lu, fx.cellA); err == nil {
		t.Error("неизвестный источник прошёл CHECK")
	}
	if _, err := fx.pool.Exec(ctx, `
		INSERT INTO placements (load_unit_id, from_cell_id, to_cell_id, source)
		VALUES ($1::uuid, $2::uuid, $2::uuid, 'putaway')`, lu, fx.cellA); err == nil {
		t.Error("перенос в ту же ячейку прошёл CHECK")
	}
}

// Миграция 000017 восстанавливает историю коробам, размещённым до неё: на проде уже лежат
// оприходованные приёмки, и без первой строки журнала инвариант был бы нарушен с первого дня.
// Проверяется сам SQL миграции: журнал удаляется (down), ГЕ возвращается в состояние «до P5-01»,
// и up накатывается заново поверх живых данных.
func TestPlacements_migrationBackfillsPlacedUnits(t *testing.T) {
	fx := setupStock(t)
	ctx := context.Background()
	user := newUser(t, fx)
	placed := newLU(t, fx, model.LoadUnitBox)
	receipt := receiveBox(t, fx, user, placed, fx.cellA)
	unplaced := newLU(t, fx, model.LoadUnitBox)

	// Более поздние миграции, опирающиеся на журнал, откатываются и накатываются вокруг неё.
	// Возвраты на места (P9-07-1) ссылаются на задания - их миграция снимается первой.
	execMigration(t, fx, "000050_picking_return.down.sql")
	execMigration(t, fx, "000025_supplier_return_shipments.down.sql")
	execMigration(t, fx, "000024_problem_decisions.down.sql")
	execMigration(t, fx, "000022_movements.down.sql")
	execMigration(t, fx, "000020_task_events.down.sql")
	execMigration(t, fx, "000019_warehouse_tasks.down.sql")
	execMigration(t, fx, "000018_putaways.down.sql")
	execMigration(t, fx, "000017_placements.down.sql")
	execMigration(t, fx, "000017_placements.up.sql")
	execMigration(t, fx, "000018_putaways.up.sql")
	execMigration(t, fx, "000019_warehouse_tasks.up.sql")
	execMigration(t, fx, "000020_task_events.up.sql")
	execMigration(t, fx, "000022_movements.up.sql")
	execMigration(t, fx, "000024_problem_decisions.up.sql")
	execMigration(t, fx, "000025_supplier_return_shipments.up.sql")
	execMigration(t, fx, "000050_picking_return.up.sql")

	hist, err := repository.NewLoadUnitRepository(fx.pool).Placements(ctx, placed)
	mustNoErr(t, err)
	if len(hist) != 1 {
		t.Fatalf("строк истории после миграции: %d, ожидалась 1", len(hist))
	}
	p := hist[0]
	if p.ToCellID != fx.cellA || p.FromCellID != nil || p.Source != model.PlacementReceipt {
		t.Errorf("восстановленная строка: from=%v to=%s source=%s", p.FromCellID, p.ToCellID, p.Source)
	}
	if p.ReceiptID == nil || *p.ReceiptID != receipt || p.UserID == nil || *p.UserID != user {
		t.Errorf("автор и документ не восстановлены: receipt=%v user=%v", p.ReceiptID, p.UserID)
	}

	empty, err := repository.NewLoadUnitRepository(fx.pool).Placements(ctx, unplaced)
	mustNoErr(t, err)
	if len(empty) != 0 {
		t.Errorf("неразмещённой ГЕ досталась история: %d строк", len(empty))
	}
}

// execMigration выполняет файл миграции как есть - тем же текстом, что уедет на прод.
func execMigration(t *testing.T, fx *stockFixture, name string) {
	t.Helper()
	sql, err := migrations.FS.ReadFile(name)
	if err != nil {
		t.Fatalf("прочитать миграцию %s: %v", name, err)
	}
	if _, err := fx.pool.Exec(context.Background(), string(sql)); err != nil {
		t.Fatalf("выполнить миграцию %s: %v", name, err)
	}
}
