package repository_test

import (
	"context"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/shopspring/decimal"

	"craftwms/internal/movement"
	"craftwms/internal/repository"
)

// Состав ГЕ для разворота движений (P4-09-1): то, что домен получает из базы.
// Переиспользуют фикстуру setupStock и newLU (load_units_integration_test.go).

// putContent кладёт позицию в состав ГЕ.
func putContent(t *testing.T, fx *stockFixture, lu, good, batch, qty string) {
	t.Helper()
	if _, err := fx.pool.Exec(context.Background(), `
		INSERT INTO lu_content (load_unit_id, good_id, batch_id, qty)
		VALUES ($1::uuid, $2::uuid, $3::uuid, $4::numeric)`, lu, good, batch, qty); err != nil {
		t.Fatalf("состав ГЕ: %v", err)
	}
}

// nest вкладывает ГЕ child в parent.
func nest(t *testing.T, fx *stockFixture, child, parent string) {
	t.Helper()
	if _, err := fx.pool.Exec(context.Background(),
		`UPDATE load_units SET parent_id = $2::uuid WHERE id = $1::uuid`, child, parent); err != nil {
		t.Fatalf("вложить ГЕ: %v", err)
	}
}

// newBatch заводит вторую партию товара фикстуры.
func newBatch(t *testing.T, fx *stockFixture, date string) string {
	t.Helper()
	var id string
	if err := fx.pool.QueryRow(context.Background(), `
		INSERT INTO batches (good_id, production_date) VALUES ($1::uuid, $2::date)
		RETURNING id::text`, fx.good, date).Scan(&id); err != nil {
		t.Fatalf("партия: %v", err)
	}
	return id
}

// Паллета с двумя коробами: её состав - всё, что в коробах, сложенное по партиям;
// короб внутри паллеты по-прежнему отдаёт только своё.
func TestLoadUnitContents_nestedSummedByBatch(t *testing.T) {
	fx := setupStock(t)
	batch2 := newBatch(t, fx, "2026-02-02")
	pallet := newLU(t, fx, "pallet")
	box1 := newLU(t, fx, "box")
	box2 := newLU(t, fx, "box")
	nest(t, fx, box1, pallet)
	nest(t, fx, box2, pallet)
	putContent(t, fx, box1, fx.good, fx.batch, "12")
	putContent(t, fx, box2, fx.good, fx.batch, "12")
	putContent(t, fx, box2, fx.good, batch2, "1.5")

	got, err := repository.NewLoadUnitContents(fx.pool).Contents(context.Background(), []string{pallet, box1})
	if err != nil {
		t.Fatal(err)
	}
	byBatch := map[string]decimal.Decimal{}
	for _, c := range got[pallet] {
		byBatch[c.BatchID] = c.Qty
	}
	if len(got[pallet]) != 2 || !byBatch[fx.batch].Equal(decimal.NewFromInt(24)) ||
		!byBatch[batch2].Equal(decimal.RequireFromString("1.5")) {
		t.Fatalf("состав паллеты: %+v", got[pallet])
	}
	if len(got[box1]) != 1 || !got[box1][0].Qty.Equal(decimal.NewFromInt(12)) {
		t.Fatalf("состав короба: %+v", got[box1])
	}
}

// Пустая ГЕ есть в ответе с пустым составом, несуществующей - нет: домен должен отличать
// «короб пуст» от «такого короба нет».
func TestLoadUnitContents_emptyVersusMissing(t *testing.T) {
	fx := setupStock(t)
	empty := newLU(t, fx, "box")
	ghost := uuid.NewString()

	got, err := repository.NewLoadUnitContents(fx.pool).Contents(context.Background(), []string{empty, ghost})
	if err != nil {
		t.Fatal(err)
	}
	c, ok := got[empty]
	if !ok || len(c) != 0 {
		t.Fatalf("пустая ГЕ: есть=%v состав=%+v", ok, c)
	}
	if _, ok := got[ghost]; ok {
		t.Fatal("несуществующая ГЕ попала в ответ")
	}
}

// Цикл вложенности (A в B, B в A) схема не запрещает. Обход обязан завершиться, а не
// повесить транзакцию операции.
func TestLoadUnitContents_cycleTerminates(t *testing.T) {
	fx := setupStock(t)
	a := newLU(t, fx, "box")
	b := newLU(t, fx, "box")
	putContent(t, fx, a, fx.good, fx.batch, "1")
	putContent(t, fx, b, fx.good, fx.batch, "2")
	nest(t, fx, a, b)
	nest(t, fx, b, a)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	got, err := repository.NewLoadUnitContents(fx.pool).Contents(ctx, []string{a})
	if err != nil {
		t.Fatalf("обход цикла не завершился: %v", err)
	}
	// Каждый узел учтён ровно один раз: 1 + 2.
	if len(got[a]) != 1 || !got[a][0].Qty.Equal(decimal.NewFromInt(3)) {
		t.Fatalf("состав при цикле: %+v", got[a])
	}
}

// Сквозной случай: домен разворачивает движения по составу, прочитанному из базы, - внутри
// транзакции, как это будет делать операция.
func TestLoadUnitContents_expandInsideTx(t *testing.T) {
	fx := setupStock(t)
	box := newLU(t, fx, "box")
	putContent(t, fx, box, fx.good, fx.batch, "10")

	var lines []movement.Line
	err := repository.WithinTx(context.Background(), fx.pool, func(q repository.Querier) error {
		var err error
		lines, err = movement.Expand(context.Background(), []movement.Move{
			{FromCellID: fx.cellA, ToCellID: fx.cellB, LoadUnitID: box},
			{FromCellID: fx.cellA, ToCellID: fx.cellB, GoodID: fx.good, BatchID: fx.batch, Qty: decimal.NewFromInt(5)},
		}, repository.NewLoadUnitContents(q))
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(lines) != 1 || !lines[0].Qty.Equal(decimal.NewFromInt(15)) || lines[0].ToCellID != fx.cellB {
		t.Fatalf("развёрнутые строки: %+v", lines)
	}
}
