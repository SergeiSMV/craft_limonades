package repository_test

import (
	"context"
	"testing"

	"github.com/google/uuid"

	"craftwms/internal/model"
	"craftwms/internal/repository"
)

// Тесты P6-01: журнал движений. Критерий задачи — фиксируются оба типа движений: перемещение
// (ГЕ целиком или товар) и пополнение; товар у обоих ходит между коробами и россыпью в любых
// сочетаниях. Фикстура setupStock — из stock_integration_test.go, newLU — из
// load_units_integration_test.go, newUser и receiveBox — из placements_integration_test.go.

// movementLine — строка движения в виде, удобном тестам: пустая строка — NULL.
type movementLine struct {
	lu, good, batch, qty, iwh string
	fromLU, toLU              string
	fromCell, toCell          string
}

// newMovement открывает документ движения вида kind и возвращает его id.
func newMovement(t *testing.T, fx *stockFixture, kind, user string) string {
	t.Helper()
	id := uuid.NewString()
	if _, err := fx.pool.Exec(context.Background(), `
		INSERT INTO movements (id, kind, warehouse_id, created_by)
		SELECT $1::uuid, $2, warehouse_id, $3::uuid FROM cells WHERE id = $4::uuid`,
		id, kind, user, fx.cellA); err != nil {
		t.Fatalf("открыть документ движения: %v", err)
	}
	return id
}

// insertMovementLine пишет строку движения; ошибку возвращает — тесты схемы её и ждут.
func insertMovementLine(fx *stockFixture, movement string, no int, l movementLine) error {
	_, err := fx.pool.Exec(context.Background(), `
		INSERT INTO movement_lines
			(movement_id, line_no, load_unit_id, good_id, batch_id, qty, internal_warehouse_id,
			 from_load_unit_id, to_load_unit_id, from_cell_id, to_cell_id)
		VALUES ($1::uuid, $2, NULLIF($3,'')::uuid, NULLIF($4,'')::uuid, NULLIF($5,'')::uuid,
		        NULLIF($6,'')::numeric, NULLIF($7,'')::uuid, NULLIF($8,'')::uuid,
		        NULLIF($9,'')::uuid, $10::uuid, $11::uuid)`,
		movement, no, l.lu, l.good, l.batch, l.qty, l.iwh, l.fromLU, l.toLU, l.fromCell, l.toCell)
	return err
}

// goods — товарная строка фикстуры с количеством 3 в склад по умолчанию.
func goods(fx *stockFixture, fromCell, fromLU, toCell, toLU string) movementLine {
	return movementLine{
		good: fx.good, batch: fx.batch, qty: "3", iwh: fx.iwh,
		fromLU: fromLU, toLU: toLU, fromCell: fromCell, toCell: toCell,
	}
}

// Критерий задачи: перемещение и пополнение пишутся в журнал со всеми своими ветками.
func TestMovements_bothKindsRecorded(t *testing.T) {
	fx := setupStock(t)
	ctx := context.Background()
	user := newUser(t, fx)
	boxA := newLU(t, fx, model.LoadUnitBox)
	boxB := newLU(t, fx, model.LoadUnitBox)

	move := newMovement(t, fx, model.MovementMove, user)
	mustNoErr(t, insertMovementLine(fx, move, 1, movementLine{lu: boxA, fromCell: fx.cellA, toCell: fx.cellB}))
	mustNoErr(t, insertMovementLine(fx, move, 2, goods(fx, fx.cellA, "", fx.cellB, "")))
	// Товар из короба в короб — тоже перемещение: источник и приёмник задаются QR коробов.
	mustNoErr(t, insertMovementLine(fx, move, 3, goods(fx, fx.cellA, boxA, fx.cellB, boxB)))

	// Пополнение: ГЕ→ГЕ, ГЕ→россыпь, россыпь→ГЕ, россыпь→россыпь. Две строки — внутри одной
	// ячейки: из короба в россыпь рядом и из россыпи в короб рядом — это законные движения.
	repl := newMovement(t, fx, model.MovementReplenish, user)
	mustNoErr(t, insertMovementLine(fx, repl, 1, goods(fx, fx.cellA, boxA, fx.cellB, boxB)))
	mustNoErr(t, insertMovementLine(fx, repl, 2, goods(fx, fx.cellA, boxA, fx.cellA, "")))
	mustNoErr(t, insertMovementLine(fx, repl, 3, goods(fx, fx.cellB, "", fx.cellB, boxB)))
	mustNoErr(t, insertMovementLine(fx, repl, 4, goods(fx, fx.cellA, "", fx.cellB, "")))

	var moves, repls string
	mustScan(t, fx.pool, `
		SELECT count(*)::text FROM movement_lines l JOIN movements m ON m.id = l.movement_id
		WHERE m.kind = 'move'`, &moves)
	mustScan(t, fx.pool, `
		SELECT count(*)::text FROM movement_lines l JOIN movements m ON m.id = l.movement_id
		WHERE m.kind = 'replenish'`, &repls)
	if moves != "3" || repls != "4" {
		t.Errorf("строк: перемещение %s, пополнение %s; ожидалось 3 и 4", moves, repls)
	}

	// История ячейки — то, по чему пересчёт (P10) узнаёт, что ячейку трогали.
	var touched string
	mustScan(t, fx.pool, `
		SELECT count(*)::text FROM movement_lines
		WHERE from_cell_id = $1::uuid OR to_cell_id = $1::uuid`, &touched, fx.cellB)
	if touched != "6" {
		t.Errorf("движений через ячейку B: %s, ожидалось 6", touched)
	}

	// Повтор документа упирается в первичный ключ: второй раз он не проводится.
	if _, err := fx.pool.Exec(ctx, `
		INSERT INTO movements (id, kind, warehouse_id, created_by)
		SELECT id, kind, warehouse_id, created_by FROM movements WHERE id = $1::uuid`, move); err == nil {
		t.Error("документ движения с тем же id записался второй раз")
	}
}

// Схема не пускает строки, которые не описывают движения.
func TestMovements_schemaGuards(t *testing.T) {
	fx := setupStock(t)
	ctx := context.Background()
	user := newUser(t, fx)
	box := newLU(t, fx, model.LoadUnitBox)
	mv := newMovement(t, fx, model.MovementMove, user)

	if _, err := fx.pool.Exec(ctx, `
		INSERT INTO movements (id, kind, warehouse_id, created_by)
		SELECT $1::uuid, 'teleport', warehouse_id, $2::uuid FROM cells WHERE id = $3::uuid`,
		uuid.NewString(), user, fx.cellA); err == nil {
		t.Error("неизвестный вид документа прошёл CHECK")
	}

	otherGood := ""
	mustScan(t, fx.pool, `INSERT INTO goods (name, uom) VALUES ('Другой','шт') RETURNING id::text`, &otherGood)

	bad := map[string]movementLine{
		"ГЕ и товар в одной строке": {lu: box, good: fx.good, batch: fx.batch, qty: "1", iwh: fx.iwh,
			fromCell: fx.cellA, toCell: fx.cellB},
		"ни ГЕ, ни товара":          {fromCell: fx.cellA, toCell: fx.cellB},
		"ГЕ целиком на месте":       {lu: box, fromCell: fx.cellA, toCell: fx.cellA},
		"ГЕ целиком из короба":      {lu: box, fromLU: box, fromCell: fx.cellA, toCell: fx.cellB},
		"товар без движения":        goods(fx, fx.cellA, "", fx.cellA, ""),
		"товар из короба в него же": goods(fx, fx.cellA, box, fx.cellA, box),
		"товар без внутреннего склада": {good: fx.good, batch: fx.batch, qty: "1",
			fromCell: fx.cellA, toCell: fx.cellB},
		"нулевое количество": {good: fx.good, batch: fx.batch, qty: "0", iwh: fx.iwh,
			fromCell: fx.cellA, toCell: fx.cellB},
		"партия чужого товара": {good: otherGood, batch: fx.batch, qty: "1", iwh: fx.iwh,
			fromCell: fx.cellA, toCell: fx.cellB},
	}
	no := 0
	for name, l := range bad {
		no++
		if err := insertMovementLine(fx, mv, no, l); err == nil {
			t.Errorf("%s: строка прошла схему", name)
		}
	}
}

// Перемещение ГЕ попадает и в журнал размещений: источник `move` и ссылка на документ.
func TestMovements_placementLinksDocument(t *testing.T) {
	fx := setupStock(t)
	ctx := context.Background()
	user := newUser(t, fx)
	lu := newLU(t, fx, model.LoadUnitBox)
	receiveBox(t, fx, user, lu, fx.cellA)
	mv := newMovement(t, fx, model.MovementMove, user)

	mustNoErr(t, repository.PlaceLoadUnitForTest(ctx, fx.pool, model.PlaceLoadUnitInput{
		LoadUnitID: lu, CellID: fx.cellB, Source: model.PlacementMove, UserID: user, MovementID: &mv,
	}))

	hist, err := repository.NewLoadUnitRepository(fx.pool).Placements(ctx, lu)
	mustNoErr(t, err)
	last := hist[len(hist)-1]
	if last.Source != model.PlacementMove || last.MovementID == nil || *last.MovementID != mv {
		t.Errorf("последняя строка: источник %s, документ %v; ожидалось move и %s", last.Source, last.MovementID, mv)
	}
	if last.ToCellID != fx.cellB || currentCell(t, fx, lu) != fx.cellB {
		t.Errorf("инвариант нарушен: текущее место не равно последней строке журнала")
	}
}

// Откат миграции не трогает историю ГЕ: строка `move` остаётся (иначе место ГЕ разошлось бы
// с журналом), а прежний набор источников действует для новых строк. Повторный накат проходит.
func TestMovements_migrationDownKeepsHistory(t *testing.T) {
	fx := setupStock(t)
	ctx := context.Background()
	user := newUser(t, fx)
	lu := newLU(t, fx, model.LoadUnitBox)
	receiveBox(t, fx, user, lu, fx.cellA)
	mv := newMovement(t, fx, model.MovementMove, user)
	mustNoErr(t, repository.PlaceLoadUnitForTest(ctx, fx.pool, model.PlaceLoadUnitInput{
		LoadUnitID: lu, CellID: fx.cellB, Source: model.PlacementMove, UserID: user, MovementID: &mv,
	}))

	execMigration(t, fx, "000022_movements.down.sql")

	var moves string
	mustScan(t, fx.pool, `SELECT count(*)::text FROM placements WHERE source = 'move'`, &moves)
	if moves != "1" {
		t.Errorf("строк move после отката: %s, ожидалась 1", moves)
	}
	if _, err := fx.pool.Exec(ctx, `
		INSERT INTO placements (load_unit_id, from_cell_id, to_cell_id, source)
		VALUES ($1::uuid, $2::uuid, $3::uuid, 'move')`, lu, fx.cellB, fx.cellA); err == nil {
		t.Error("после отката новая строка move прошла прежний набор источников")
	}

	execMigration(t, fx, "000022_movements.up.sql")
	mustNoErr(t, repository.PlaceLoadUnitForTest(ctx, fx.pool, model.PlaceLoadUnitInput{
		LoadUnitID: lu, CellID: fx.cellA, Source: model.PlacementMove, UserID: user,
	}))
}
