package repository_test

import (
	"context"
	"strings"
	"testing"

	"github.com/google/uuid"
)

// Тесты P4-01: схема грузовой единицы и её состава.
// Кода поверх неё ещё нет (репозиторий появится в P4-03), поэтому проверяются инварианты самой
// схемы — то, на что дальше будет опираться домен приёмки.
// Переиспользуют фикстуру setupStock (склад/ячейки/товар/партия) из stock_integration_test.go.

// newLU заводит ГЕ с идентификатором, выданным «устройством», и возвращает его.
func newLU(t *testing.T, fx *stockFixture, kind string) string {
	t.Helper()
	id := uuid.NewString()
	if _, err := fx.pool.Exec(context.Background(),
		`INSERT INTO load_units (id, kind) VALUES ($1::uuid, $2)`, id, kind); err != nil {
		t.Fatalf("создать ГЕ: %v", err)
	}
	return id
}

// Базовый случай: ГЕ с составом хранится и читается — это и есть критерий задачи.
func TestLoadUnits_unitWithContent(t *testing.T) {
	fx := setupStock(t)
	ctx := context.Background()
	lu := newLU(t, fx, "box")

	if _, err := fx.pool.Exec(ctx, `
		INSERT INTO lu_content (load_unit_id, good_id, batch_id, qty)
		VALUES ($1::uuid, $2::uuid, $3::uuid, 12.5)`, lu, fx.good, fx.batch); err != nil {
		t.Fatalf("вложить товар в ГЕ: %v", err)
	}

	var kind, status, qty string
	var cell, parent *string
	if err := fx.pool.QueryRow(ctx, `
		SELECT u.kind, u.status, u.cell_id::text, u.parent_id::text, c.qty::text
		FROM load_units u
		JOIN lu_content c ON c.load_unit_id = u.id
		WHERE u.id = $1::uuid`, lu).Scan(&kind, &status, &cell, &parent, &qty); err != nil {
		t.Fatalf("прочитать ГЕ с составом: %v", err)
	}
	if kind != "box" || status != "open" {
		t.Errorf("ГЕ: kind=%q status=%q, ожидались box/open", kind, status)
	}
	// Свежая ГЕ ещё не размещена и никуда не вложена.
	if cell != nil || parent != nil {
		t.Errorf("свежая ГЕ: cell=%v parent=%v — ожидались NULL", cell, parent)
	}
	if !strings.HasPrefix(qty, "12.5") {
		t.Errorf("количество в составе: %q", qty)
	}
}

// Грань состава: повторное вложение того же товара той же партии — это одна строка,
// количество в ней меняется. Иначе состав ГЕ разъехался бы на дубли.
func TestLoadUnits_contentGrainIsUnique(t *testing.T) {
	fx := setupStock(t)
	ctx := context.Background()
	lu := newLU(t, fx, "box")

	ins := `INSERT INTO lu_content (load_unit_id, good_id, batch_id, qty) VALUES ($1::uuid,$2::uuid,$3::uuid,$4)`
	if _, err := fx.pool.Exec(ctx, ins, lu, fx.good, fx.batch, 3); err != nil {
		t.Fatalf("первое вложение: %v", err)
	}
	if _, err := fx.pool.Exec(ctx, ins, lu, fx.good, fx.batch, 5); err == nil {
		t.Fatal("вторая строка по той же грани прошла — грань не работает")
	}

	// Штатный путь — upsert по грани: количество увеличивается, строка остаётся одна.
	if _, err := fx.pool.Exec(ctx, `
		INSERT INTO lu_content (load_unit_id, good_id, batch_id, qty)
		VALUES ($1::uuid,$2::uuid,$3::uuid,$4)
		ON CONFLICT (load_unit_id, good_id, batch_id) DO UPDATE SET qty = lu_content.qty + EXCLUDED.qty`,
		lu, fx.good, fx.batch, 5); err != nil {
		t.Fatalf("upsert по грани: %v", err)
	}
	var n int
	var qty string
	if err := fx.pool.QueryRow(ctx,
		`SELECT count(*), max(qty)::text FROM lu_content WHERE load_unit_id = $1::uuid`, lu).Scan(&n, &qty); err != nil {
		t.Fatalf("счёт строк состава: %v", err)
	}
	if n != 1 || !strings.HasPrefix(qty, "8") {
		t.Errorf("после upsert: строк=%d qty=%q, ожидались 1 и 8", n, qty)
	}
}

// Вложенность: короб кладётся в паллету, и удаление паллеты не уносит короба —
// физически они никуда не делись.
func TestLoadUnits_nesting(t *testing.T) {
	fx := setupStock(t)
	ctx := context.Background()
	pallet := newLU(t, fx, "pallet")
	box := newLU(t, fx, "box")

	if _, err := fx.pool.Exec(ctx,
		`UPDATE load_units SET parent_id = $1::uuid WHERE id = $2::uuid`, pallet, box); err != nil {
		t.Fatalf("вложить короб в паллету: %v", err)
	}
	if _, err := fx.pool.Exec(ctx, `DELETE FROM load_units WHERE id = $1::uuid`, pallet); err != nil {
		t.Fatalf("удалить паллету: %v", err)
	}

	var parent *string
	if err := fx.pool.QueryRow(ctx,
		`SELECT parent_id::text FROM load_units WHERE id = $1::uuid`, box).Scan(&parent); err != nil {
		t.Fatalf("короб исчез вместе с паллетой: %v", err)
	}
	if parent != nil {
		t.Errorf("после удаления паллеты parent_id = %v, ожидался NULL", *parent)
	}

	// ГЕ не может быть вложена сама в себя — это оборвало бы обход состава.
	if _, err := fx.pool.Exec(ctx,
		`UPDATE load_units SET parent_id = id WHERE id = $1::uuid`, box); err == nil {
		t.Error("ГЕ разрешили стать своим родителем")
	}
}

// Удаление ГЕ уносит её состав: оболочка без содержимого — мусор, который потом join'ится в пустоту.
func TestLoadUnits_deleteCascadesContent(t *testing.T) {
	fx := setupStock(t)
	ctx := context.Background()
	lu := newLU(t, fx, "box")
	if _, err := fx.pool.Exec(ctx, `
		INSERT INTO lu_content (load_unit_id, good_id, batch_id, qty)
		VALUES ($1::uuid,$2::uuid,$3::uuid,1)`, lu, fx.good, fx.batch); err != nil {
		t.Fatalf("вложить товар: %v", err)
	}
	if _, err := fx.pool.Exec(ctx, `DELETE FROM load_units WHERE id = $1::uuid`, lu); err != nil {
		t.Fatalf("удалить ГЕ: %v", err)
	}
	var n int
	if err := fx.pool.QueryRow(ctx,
		`SELECT count(*) FROM lu_content WHERE load_unit_id = $1::uuid`, lu).Scan(&n); err != nil {
		t.Fatalf("счёт остатков состава: %v", err)
	}
	if n != 0 {
		t.Errorf("состав пережил удаление ГЕ: строк %d", n)
	}
}

// Ограничения-сторожа: чужой тип, чужой статус, отрицательное количество и партия не своего
// товара не должны попадать в базу — на эти инварианты будет опираться домен приёмки.
func TestLoadUnits_guards(t *testing.T) {
	fx := setupStock(t)
	ctx := context.Background()

	if _, err := fx.pool.Exec(ctx,
		`INSERT INTO load_units (id, kind) VALUES ($1::uuid,'container')`, uuid.NewString()); err == nil {
		t.Error("тип ГЕ вне списка прошёл")
	}
	lu := newLU(t, fx, "box")
	if _, err := fx.pool.Exec(ctx,
		`UPDATE load_units SET status='shipped' WHERE id=$1::uuid`, lu); err == nil {
		t.Error("статус вне списка прошёл")
	}
	if _, err := fx.pool.Exec(ctx, `
		INSERT INTO lu_content (load_unit_id, good_id, batch_id, qty)
		VALUES ($1::uuid,$2::uuid,$3::uuid,-1)`, lu, fx.good, fx.batch); err == nil {
		t.Error("отрицательное количество прошло")
	}

	// Партия принадлежит другому товару — составной FK обязан это поймать.
	var otherGood, otherBatch string
	mustScan(t, fx.pool, `INSERT INTO goods (name, uom) VALUES ('Другой','шт') RETURNING id::text`, &otherGood)
	mustScan(t, fx.pool, `INSERT INTO batches (good_id, production_date) VALUES ($1::uuid,'2026-03-03') RETURNING id::text`,
		&otherBatch, otherGood)
	if _, err := fx.pool.Exec(ctx, `
		INSERT INTO lu_content (load_unit_id, good_id, batch_id, qty)
		VALUES ($1::uuid,$2::uuid,$3::uuid,1)`, lu, fx.good, otherBatch); err == nil {
		t.Error("партия чужого товара прошла — составной FK не работает")
	}
}
