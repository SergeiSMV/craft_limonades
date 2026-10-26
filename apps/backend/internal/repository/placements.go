package repository

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"

	"craftwms/internal/model"
)

// placeLoadUnit переносит ГЕ в ячейку и пишет строку журнала размещений (P5-01).
//
// Что: единственное место, где меняется `load_units.cell_id`.
// Зачем: держит инвариант «текущее место ГЕ = `to_cell_id` её последней строки журнала». Пока
// место и история пишутся в одном месте и в одной транзакции, разойтись им негде.
// Как: строка ГЕ блокируется (`FOR UPDATE`), чтобы два одновременных переноса одной ГЕ не
// записали одно и то же «откуда»; перенос в ту же ячейку ничего не меняет и в журнал не идёт —
// это не перенос. Работает на Querier: вызывается внутри транзакции операции (приёмка,
// размещение, перемещение), а не своей.
//
// Остаток (`stock`) здесь не двигается: перенос товара между ячейками — забота вызывающей
// операции, у которой есть состав ГЕ и внутренний склад (P5-02).
func placeLoadUnit(ctx context.Context, q Querier, in model.PlaceLoadUnitInput) error {
	var from *string
	err := q.QueryRow(ctx, `
		SELECT cell_id::text FROM load_units WHERE id = $1::uuid FOR UPDATE`, in.LoadUnitID).
		Scan(&from)
	if errors.Is(err, pgx.ErrNoRows) {
		return ErrLoadUnitNotFound
	}
	if err != nil {
		return fmt.Errorf("прочитать место ГЕ: %w", err)
	}
	if from != nil && *from == in.CellID {
		return nil
	}

	if _, err := q.Exec(ctx, `
		UPDATE load_units SET cell_id = $2::uuid, status = 'placed'
		WHERE id = $1::uuid`, in.LoadUnitID, in.CellID); err != nil {
		return fmt.Errorf("разместить ГЕ: %w", err)
	}
	if _, err := q.Exec(ctx, `
		INSERT INTO placements
			(load_unit_id, from_cell_id, to_cell_id, source, receipt_id, putaway_id, movement_id, user_id,
			 stock_entry_session_id, stocktake_cell_id)
		VALUES ($1::uuid, $2::uuid, $3::uuid, $4, $5::uuid, $6::uuid, $7::uuid, NULLIF($8, '')::uuid,
		        $9::uuid, $10::uuid)`,
		in.LoadUnitID, from, in.CellID, in.Source, in.ReceiptID, in.PutawayID, in.MovementID, in.UserID,
		in.StockEntryID, in.StocktakeCellID); err != nil {
		return fmt.Errorf("записать размещение ГЕ: %w", err)
	}
	return nil
}

// Placements возвращает историю размещений ГЕ — от первого к последнему (P5-01).
//
// Пустой список — ГЕ ещё ни разу не размещали. Несуществующая ГЕ — ErrLoadUnitNotFound:
// «истории нет» и «короба нет» для кладовщика разные ответы.
func (r *LoadUnitRepository) Placements(ctx context.Context, id string) ([]model.Placement, error) {
	if err := guardLoadUnitExists(ctx, r.pool, id); err != nil {
		return nil, err
	}
	rows, err := r.pool.Query(ctx, `
		SELECT p.id::text, p.load_unit_id::text,
		       p.from_cell_id::text, cf.address,
		       p.to_cell_id::text, ct.address,
		       p.source, p.receipt_id::text, p.putaway_id::text, p.movement_id::text,
		       p.user_id::text, p.placed_at
		FROM placements p
		LEFT JOIN cells cf ON cf.id = p.from_cell_id
		JOIN cells ct      ON ct.id = p.to_cell_id
		WHERE p.load_unit_id = $1::uuid
		ORDER BY p.placed_at, p.id`, id)
	if err != nil {
		return nil, fmt.Errorf("прочитать историю ГЕ: %w", err)
	}
	defer rows.Close()

	out := []model.Placement{}
	for rows.Next() {
		var p model.Placement
		if err := rows.Scan(&p.ID, &p.LoadUnitID, &p.FromCellID, &p.FromAddress,
			&p.ToCellID, &p.ToAddress, &p.Source, &p.ReceiptID, &p.PutawayID, &p.MovementID, &p.UserID, &p.PlacedAt); err != nil {
			return nil, fmt.Errorf("разобрать историю ГЕ: %w", err)
		}
		out = append(out, p)
	}
	return out, rows.Err()
}
