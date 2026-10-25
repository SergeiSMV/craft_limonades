package repository

import (
	"context"
	"errors"
	"fmt"
	"maps"
	"slices"

	"github.com/shopspring/decimal"

	"craftwms/internal/model"
)

// problemLines — что решение офиса или отгрузка возврата берёт по проблеме: короб целиком;
// товар с марками ЧЗ — там, где лежат его марки (CZ-06); товар без марок — по количеству, где
// найдётся на складе-метке (P6-07-3).
func problemLines(ctx context.Context, q Querier, p lockedProblem) ([]problemLine, error) {
	if p.loadUnit != "" {
		return problemBoxLines(ctx, q, p)
	}
	lines, err := problemMarkLines(ctx, q, p)
	if err != nil || lines != nil {
		return lines, err
	}
	return problemGoodsLines(ctx, q, p)
}

// problemMarkLines — товар проблемы по её маркам (CZ-06): строки по ячейкам, где марки лежат
// россыпью склада-метки. Марок у проблемы нет — nil: товар берётся по количеству.
//
// Зачем по маркам: товар разных проблем одной партии неразличим по количеству, а марки — нет;
// иначе остаток списался бы в одной ячейке, а марки — в другой. Марка, ушедшая со склада-метки
// или из россыпи (переложена в короб), — товара проблемы нет там, где его ждут:
// ErrProblemGoodsMissing, как у проблемы без марок.
func problemMarkLines(ctx context.Context, q Querier, p lockedProblem) ([]problemLine, error) {
	rows, err := q.Query(ctx, `
		SELECT m.cell_id::text, m.internal_warehouse_id::text, m.load_unit_id IS NOT NULL,
		       m.good_id::text, m.batch_id::text
		FROM cz_marks m
		LEFT JOIN cells c ON c.id = m.cell_id
		WHERE m.problem_id = $1::uuid AND m.status = $2
		ORDER BY c.address, m.cis
		FOR UPDATE OF m`, p.id, model.CZMarkInStock)
	if err != nil {
		return nil, fmt.Errorf("марки проблемы: %w", err)
	}
	defer rows.Close()
	var lines []problemLine
	count := 0
	for rows.Next() {
		var cell, iwh *string
		var boxed bool
		var good, batch string
		if err := rows.Scan(&cell, &iwh, &boxed, &good, &batch); err != nil {
			return nil, fmt.Errorf("разобрать марку проблемы: %w", err)
		}
		if boxed || cell == nil || deref(iwh) != p.toIwh || good != p.good || batch != p.batch {
			return nil, ErrProblemGoodsMissing
		}
		count++
		if n := len(lines); n > 0 && lines[n-1].cell == *cell {
			lines[n-1].qty = lines[n-1].qty.Add(decimal.NewFromInt(1))
			continue
		}
		lines = append(lines, problemLine{cell: *cell, good: good, batch: batch, qty: decimal.NewFromInt(1)})
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("марки проблемы: %w", err)
	}
	if count > 0 && !p.qty.Equal(decimal.NewFromInt(int64(count))) {
		return nil, ErrProblemGoodsMissing
	}
	return lines, nil
}

// retireProblemMarks уводит со склада марки проблемы статусом status (CZ-06): короб — все
// марки в нём, товар — марки проблемы. Ушедшая марка места не имеет (CHECK cz_marks_place).
func retireProblemMarks(ctx context.Context, q Querier, p lockedProblem, status string) error {
	var err error
	if p.loadUnit != "" {
		_, err = q.Exec(ctx, `
			UPDATE cz_marks SET status = $2, load_unit_id = NULL, cell_id = NULL,
			       internal_warehouse_id = NULL, updated_at = now()
			WHERE load_unit_id = $1::uuid AND status = $3`, p.loadUnit, status, model.CZMarkInStock)
	} else {
		_, err = q.Exec(ctx, `
			UPDATE cz_marks SET status = $2, load_unit_id = NULL, cell_id = NULL,
			       internal_warehouse_id = NULL, updated_at = now()
			WHERE problem_id = $1::uuid AND status = $3`, p.id, status, model.CZMarkInStock)
	}
	if err != nil {
		return fmt.Errorf("марки проблемы со склада: %w", err)
	}
	return nil
}

// relabelProblemMarks переводит марки товара проблемы на склад to — вместе с остатком
// (CZ-06): марки россыпью несут склад строки. Марки короба склада не несут — его меняет короб.
func relabelProblemMarks(ctx context.Context, q Querier, p lockedProblem, to string) error {
	if _, err := q.Exec(ctx, `
		UPDATE cz_marks SET internal_warehouse_id = $2::uuid, updated_at = now()
		WHERE problem_id = $1::uuid AND status = $3 AND cell_id IS NOT NULL`,
		p.id, to, model.CZMarkInStock); err != nil {
		return fmt.Errorf("марки проблемы на другой склад: %w", err)
	}
	return nil
}

// CZRejection — отказ операции по маркам ЧЗ с причиной по-русски (CZ-06).
//
// Зачем: строки документов движения называют свою причину по-русски (ADHOC-40), а пометка
// проблемы и отгрузка возврата отказывают целиком — без обёртки кладовщик увидел бы код ошибки
// по-английски. Unwrap отдаёт ошибку-сигнал: очередь по-прежнему узнаёт отказ по существу.
type CZRejection struct {
	Text string
	Err  error
}

func (e *CZRejection) Error() string { return e.Text }

// Unwrap — ошибка-сигнал отказа.
func (e *CZRejection) Unwrap() error { return e.Err }

// czRejection оборачивает ошибку марок ЧЗ причиной по-русски с префиксом [what]; прочие
// ошибки (сбой базы) — как есть.
func czRejection(err error, what string) error {
	for _, target := range []error{
		model.ErrCZMarksRequired, model.ErrCZMarksQtyMismatch,
		model.ErrCZMarkNotAtSource, model.ErrCZMarkBatchMismatch,
	} {
		if errors.Is(err, target) {
			return &CZRejection{Text: what + ": " + lineReason(err), Err: err}
		}
	}
	return err
}

// returnMarks — марки, отсканированные в сеансе отгрузки возврата (CZ-06, долг 30): каждая
// должна принадлежать позиции сеанса, и каждая позиция россыпью с марками — быть названа
// целиком.
type returnMarks struct {
	pending map[string]bool // ещё не отнесённые к позиции
}

func newReturnMarks(cis []string) *returnMarks {
	r := &returnMarks{pending: make(map[string]bool, len(cis))}
	for _, c := range cis {
		r.pending[c] = true
	}
	return r
}

// take относит к позиции p её марки. Короб уезжает целиком — его марки сканировать незачем;
// позиция россыпью без марок — по-прежнему одним сканом товара.
func (r *returnMarks) take(ctx context.Context, q Querier, p lockedProblem) error {
	if p.loadUnit != "" {
		return nil
	}
	rows, err := q.Query(ctx, `
		SELECT cis FROM cz_marks WHERE problem_id = $1::uuid AND status = $2`,
		p.id, model.CZMarkInStock)
	if err != nil {
		return fmt.Errorf("марки позиции возврата: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var cis string
		if err := rows.Scan(&cis); err != nil {
			return fmt.Errorf("разобрать марку позиции: %w", err)
		}
		if !r.pending[cis] {
			return &CZRejection{
				Text: "Отсканированы не все марки позиции возврата «" +
					goodText(ctx, q, p.good, "", decimal.Zero) + "» — отсканируйте каждую единицу",
				Err: model.ErrCZReturnMarksIncomplete,
			}
		}
		delete(r.pending, cis)
	}
	return rows.Err()
}

// allTaken — все отсканированные марки нашли свою позицию; лишняя — отказ сеанса.
func (r *returnMarks) allTaken() error {
	if len(r.pending) == 0 {
		return nil
	}
	// Первая по порядку — чтобы причина не зависела от обхода словаря.
	extra := slices.Sorted(maps.Keys(r.pending))[0]
	return &CZRejection{
		Text: "Марка " + extra + " не из позиций этого возврата — уберите её из сеанса",
		Err:  model.ErrCZReturnMarkForeign,
	}
}
