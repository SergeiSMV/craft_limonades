package repository

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/shopspring/decimal"

	"craftwms/internal/model"
)

// markPlace — место марки на складе (CZ-06): в коробе (loadUnitID) ЛИБО россыпью в ячейке
// (cellID) строкой внутреннего склада iwh. Ячейку марки в коробе хранит короб, не марка.
type markPlace struct {
	loadUnitID string
	cellID     string
	iwh        string
}

// placeOf — место для строки товара: короб, если он есть, иначе россыпь ячейки.
func placeOf(loadUnitID, cellID, iwh string) markPlace {
	if loadUnitID != "" {
		return markPlace{loadUnitID: loadUnitID}
	}
	return markPlace{cellID: cellID, iwh: iwh}
}

// lockedMark — марка под блокировкой: чья она и где лежит сейчас.
type lockedMark struct {
	cis, good, batch, status string
	place                    markPlace
}

// moveMarks переносит марки строки товара из источника в приёмник (CZ-06).
//
// Что: у маркируемого товара (`goods.cz_marked`) строка россыпи или из короба несёт КИ каждой
//
//	единицы; марки переезжают туда же, куда остаток, и упаковка ЧЗ, из которой вынута марка,
//	становится вскрытой.
//
// Зачем здесь, а не в вызывающих: перемещение, размещение россыпи и пометка проблемы двигают
//
//	товар по-разному, а правило «где лежит марка» одно — две копии разошлись бы.
//
// Как: марки блокируются (FOR UPDATE) в порядке КИ — два документа с одними марками не
//
//	сцепятся; каждая обязана быть на складе, своего товара и партии и лежать в источнике.
//	Немаркируемый товар без марок проходит как раньше; марки при нём — тоже учитываются:
//	товар мог стать маркируемым позже.
func moveMarks(ctx context.Context, q Querier, goodID, batchID string, marks []string, qty decimal.Decimal, from, to markPlace) error {
	if len(marks) == 0 {
		var marked bool
		err := q.QueryRow(ctx, `SELECT cz_marked FROM goods WHERE id = $1::uuid`, goodID).Scan(&marked)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrUnknownReference
		}
		if err != nil {
			return fmt.Errorf("признак маркировки товара: %w", err)
		}
		if marked {
			return model.ErrCZMarksRequired
		}
		return nil
	}
	if !qty.Equal(decimal.NewFromInt(int64(len(marks)))) {
		return model.ErrCZMarksQtyMismatch
	}
	locked, err := lockMarks(ctx, q, marks)
	if err != nil {
		return err
	}
	for _, m := range locked {
		if m.good != goodID || m.batch != batchID {
			return model.ErrCZMarkBatchMismatch
		}
		if m.status != model.CZMarkInStock || m.place != from {
			return model.ErrCZMarkNotAtSource
		}
	}
	if _, err := q.Exec(ctx, `
		UPDATE cz_marks
		SET load_unit_id = NULLIF($2, '')::uuid, cell_id = NULLIF($3, '')::uuid,
		    internal_warehouse_id = NULLIF($4, '')::uuid, updated_at = now()
		WHERE cis = ANY($1::text[])`, marks, to.loadUnitID, to.cellID, to.iwh); err != nil {
		return fmt.Errorf("перенести марки: %w", err)
	}
	return openTouchedAggregates(ctx, q, marks)
}

// lockMarks блокирует марки по КИ и возвращает их состояние. Хоть одной нет — ErrCZMarkNotAtSource:
// марки, которой склад не знает, нет и в источнике.
func lockMarks(ctx context.Context, q Querier, marks []string) ([]lockedMark, error) {
	rows, err := q.Query(ctx, `
		SELECT cis, good_id::text, batch_id::text, status,
		       COALESCE(load_unit_id::text, ''), COALESCE(cell_id::text, ''),
		       COALESCE(internal_warehouse_id::text, '')
		FROM cz_marks WHERE cis = ANY($1::text[])
		ORDER BY cis
		FOR UPDATE`, marks)
	if err != nil {
		return nil, fmt.Errorf("заблокировать марки: %w", err)
	}
	defer rows.Close()
	var out []lockedMark
	for rows.Next() {
		var m lockedMark
		if err := rows.Scan(&m.cis, &m.good, &m.batch, &m.status,
			&m.place.loadUnitID, &m.place.cellID, &m.place.iwh); err != nil {
			return nil, fmt.Errorf("разобрать марку: %w", err)
		}
		out = append(out, m)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("заблокировать марки: %w", err)
	}
	if len(out) != len(marks) {
		return nil, model.ErrCZMarkNotAtSource
	}
	return out, nil
}

// openTouchedAggregates помечает вскрытыми упаковки ЧЗ, из которых вынуты марки (CZ-06).
//
// Что: проверяются упаковки, в которых пришли тронутые марки, и упаковки над ними (групповая
//
//	внутри короба). Упаковка вскрыта, если хоть одна её марка — прямо или во вложенной
//	упаковке — ушла со склада, лежит не в коробе ЧЗ, которым упаковка является, или (у
//	групповой упаковки) лежит не там же, где остальные её марки.
//
// Зачем по факту, а не «каждое изъятие»: групповую упаковку целиком перекладывают одним
//
//	сканом, и она остаётся целой; вынутая из неё бутылка — вскрывает.
//
// Как: одним UPDATE; вскрытие не снимается — `opened_at` ставится один раз. Вложенность —
//
//	на один уровень (групповая в коробе), глубже в пилоте её нет (CZ-01).
func openTouchedAggregates(ctx context.Context, q Querier, marks []string) error {
	if _, err := q.Exec(ctx, `
		WITH touched AS (
			SELECT DISTINCT aggregate_code AS code FROM cz_marks
			WHERE cis = ANY($1::text[]) AND aggregate_code IS NOT NULL
		), candidates AS (
			SELECT code FROM touched
			UNION
			SELECT a.parent_code FROM cz_aggregates a
			WHERE a.code IN (SELECT code FROM touched) AND a.parent_code IS NOT NULL
		), members AS (
			SELECT c.code AS agg, m.status, m.load_unit_id, m.cell_id, m.internal_warehouse_id
			FROM candidates c
			JOIN cz_marks m ON m.aggregate_code = c.code
			                OR m.aggregate_code IN (SELECT g.code FROM cz_aggregates g WHERE g.parent_code = c.code)
		)
		UPDATE cz_aggregates a SET opened_at = now(), updated_at = now()
		WHERE a.code IN (SELECT code FROM candidates) AND a.opened_at IS NULL
		  AND EXISTS (
			SELECT 1 FROM members x
			WHERE x.agg = a.code
			  AND (x.status <> $2
			       OR (a.load_unit_id IS NOT NULL AND x.load_unit_id IS DISTINCT FROM a.load_unit_id)
			       OR (a.load_unit_id IS NULL AND EXISTS (
			              SELECT 1 FROM members y
			              WHERE y.agg = a.code
			                AND (y.load_unit_id IS DISTINCT FROM x.load_unit_id
			                     OR y.cell_id IS DISTINCT FROM x.cell_id
			                     OR y.internal_warehouse_id IS DISTINCT FROM x.internal_warehouse_id)))))`,
		marks, model.CZMarkInStock); err != nil {
		return fmt.Errorf("отметить вскрытые упаковки ЧЗ: %w", err)
	}
	return nil
}
