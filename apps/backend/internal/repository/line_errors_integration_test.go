package repository_test

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/google/uuid"

	"craftwms/internal/model"
	"craftwms/internal/repository"
)

// Тесты ADHOC-40 (долг 26): документ называет все плохие строки сразу, а не первую.

// linesError достаёт список отклонённых строк из отказа документа.
func linesError(t *testing.T, err error) *repository.DocumentLinesError {
	t.Helper()
	var lines *repository.DocumentLinesError
	if !errors.As(err, &lines) {
		t.Fatalf("ожидался отказ со списком строк, получено: %v", err)
	}
	return lines
}

// Две плохие строки из трёх - в отказе обе, по-русски и названные содержимым; хорошая строка
// между ними не проведена: документ откатывается целиком.
func TestMove_allBadLinesNamed(t *testing.T) {
	mf := setupMove(t)
	_, _ = mf.twoBoxes(t) // A: короб 12 + россыпь 5; B: короб 12
	ghost := uuid.NewString()

	mv := uuid.NewString()
	_, err := mf.move(t, mv,
		mf.goodsLine(100, mf.cellA, "", mf.cellB, ""), // россыпи в A только 5
		mf.goodsLine(2, mf.cellA, "", mf.cellB, ""),   // хорошая
		luTo(ghost, mf.cellC),                         // такого короба нет
	)
	lines := linesError(t, err)
	if lines.Total != 3 || len(lines.Lines) != 2 || lines.Lines[0].Line != 1 || lines.Lines[1].Line != 3 {
		t.Fatalf("отклонены строки %+v из %d, ожидались 1 и 3 из 3", lines.Lines, lines.Total)
	}
	if !errors.Is(err, model.ErrGoodsShort) || !errors.Is(err, model.ErrLoadUnitNotFound) {
		t.Errorf("причины строк не видны через errors.Is: %v", err)
	}
	msg := err.Error()
	for _, want := range []string{
		"Отклонено строк: 2 из 3",
		"Товар · партия 01.01.2026 · 100 шт: A → B: в источнике не хватает товара этой партии",
		"короб " + strings.ToUpper(strings.ReplaceAll(ghost, "-", ""))[24:28] + " ",
		"→ C: короб не найден",
	} {
		if !strings.Contains(msg, want) {
			t.Errorf("в тексте отказа нет %q:\n%s", want, msg)
		}
	}

	if a, b := mf.qtyOf(t, mf.cellA, mf.batch), mf.qtyOf(t, mf.cellB, mf.batch); a != "17" || b != "12" {
		t.Errorf("остаток A=%s B=%s, ожидалось 17 и 12 - документ не должен был провестись", a, b)
	}
	var docs string
	mustScan(t, mf.pool, `SELECT count(*)::text FROM movements WHERE id = $1::uuid`, &docs, mv)
	if docs != "0" {
		t.Error("отклонённый документ оставил шапку")
	}
}

// Отклонённая строка откатывается до проверки следующей. Первая строка переносит короб из A
// и падает уже после переноса: A - ячейка приёмки, проверка источника идёт после переноса.
// Вторая берёт товар из того же короба: если откат строки сработал, короб снова в A, и она
// упирается в ту же ячейку приёмки; без отката короб оказался бы в C, и строка прошла бы.
func TestMove_rejectedLineRolledBackBeforeNext(t *testing.T) {
	mf := setupMove(t)
	boxA, _ := mf.twoBoxes(t)
	mf.setReceiving(t, mf.cellA)

	_, err := mf.move(t, uuid.NewString(),
		luTo(boxA, mf.cellC),
		mf.goodsLine(2, "", boxA, mf.cellB, ""),
	)
	lines := linesError(t, err)
	if len(lines.Lines) != 2 {
		t.Fatalf("отклонены %+v, ожидались обе строки: короб после отката первой - снова в A", lines.Lines)
	}
	for _, l := range lines.Lines {
		if !errors.Is(l.Err, model.ErrReceivingCell) {
			t.Errorf("строка %d: %v, ожидалась ErrReceivingCell", l.Line, l.Err)
		}
	}
	if currentCell(t, mf.stockFixture, boxA) != mf.cellA {
		t.Error("короб не вернулся в A")
	}
}

// Ошибка SQL внутри строки не роняет транзакцию: после отката к точке запросы идут дальше.
func TestTryLine_sqlErrorDoesNotAbortTransaction(t *testing.T) {
	mf := setupMove(t)
	rejected, fatal, after := repository.TryLineAfterSQLErrorForTest(context.Background(), mf.pool)
	if fatal != nil {
		t.Fatalf("ошибка ссылки оборвала проверку: %v", fatal)
	}
	if !errors.Is(rejected, model.ErrUnknownReference) {
		t.Errorf("отказ строки: %v, ожидалась ErrUnknownReference", rejected)
	}
	if after != nil {
		t.Errorf("после отката к точке транзакция мертва: %v", after)
	}
}

// Размещение: отклонённая строка россыпи не уменьшает остаток задания для следующих строк.
// Первая строка списывает 6 с задания и падает (ячейка та же), вторая размещает все 10 -
// без восстановления остатка задания она упёрлась бы в «больше, чем осталось».
func TestPutaway_rejectedLineKeepsTaskRemainder(t *testing.T) {
	pf := setupPutaway(t)
	task := pf.receive(t, nil, 10)

	_, err := pf.submit(t, task, uuid.NewString(),
		looseTo(pf.good, 6, pf.cellA), // в ячейку приёмки, откуда и берём
		looseTo(pf.good, 10, pf.cellB),
	)
	lines := linesError(t, err)
	if len(lines.Lines) != 1 || lines.Lines[0].Line != 1 || !errors.Is(err, model.ErrPutawaySameCell) {
		t.Fatalf("отклонены %+v, ожидалась только строка 1 (ErrPutawaySameCell)", lines.Lines)
	}
	if !strings.Contains(err.Error(), "Товар · партия 01.01.2026 · 6 шт → A: уже лежит в этой ячейке") {
		t.Errorf("текст отказа:\n%s", err.Error())
	}
	if pf.qtyIn(t, pf.cellB) != "0" {
		t.Error("хорошая строка проведена, хотя сеанс отклонён")
	}
}

// Отказ документа целиком (не строки) - по-прежнему обычной ошибкой, без списка.
func TestMove_documentLevelErrorUnchanged(t *testing.T) {
	mf := setupMove(t)
	_, _ = mf.twoBoxes(t)
	_, err := repository.MovementSubmitForTest(context.Background(), mf.pool, repository.MovementSubmitInput{
		MovementID: uuid.NewString(), Kind: "teleport", WarehouseID: mf.wh, CreatedBy: mf.user,
		Lines: []repository.MovementLineInput{mf.goodsLine(1, mf.cellA, "", mf.cellB, "")},
	})
	var lines *repository.DocumentLinesError
	if errors.As(err, &lines) || !errors.Is(err, model.ErrUnknownMovementKind) {
		t.Errorf("вид документа: %v, ожидалась ErrUnknownMovementKind без списка строк", err)
	}
}
