package repository

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5/pgxpool"

	"craftwms/internal/model"
)

// GoodsRepository — доступ к таблице goods (номенклатура). Пока — апсерт под импорт;
// чтение/поиск/пагинация добавятся в P1-06.
type GoodsRepository struct {
	pool *pgxpool.Pool
}

// NewGoodsRepository создаёт репозиторий номенклатуры.
func NewGoodsRepository(pool *pgxpool.Pool) *GoodsRepository {
	return &GoodsRepository{pool: pool}
}

// Upsert заводит/обновляет товар по «Коду» из 1С (ключ апсерта). Возвращает created=true,
// если строка была вставлена (новый товар), false — если обновлена (повторный импорт).
// groupID/supplierID — nil, если не заданы. Идемпотентно: повторный импорт того же файла не двоит.
func (r *GoodsRepository) Upsert(ctx context.Context, q Querier, code, name, fullName, uom string, groupID, supplierID *string) (bool, error) {
	var inserted bool
	// (xmax = 0) — идиома Postgres: у только что вставленной строки xmax=0 → created=true;
	// у обновлённой по ON CONFLICT xmax≠0 → created=false.
	err := q.QueryRow(ctx, `
		INSERT INTO goods (code, name, full_name, uom, group_id, supplier_id)
		VALUES ($1, $2, $3, $4, $5::uuid, $6::uuid)
		ON CONFLICT (code) DO UPDATE SET
			name        = EXCLUDED.name,
			full_name   = EXCLUDED.full_name,
			uom         = EXCLUDED.uom,
			group_id    = EXCLUDED.group_id,
			supplier_id = EXCLUDED.supplier_id
		RETURNING (xmax = 0) AS inserted`,
		code, name, fullName, uom, groupID, supplierID).Scan(&inserted)
	if err != nil {
		return false, fmt.Errorf("upsert good %q: %w", code, err)
	}
	return inserted, nil
}

// ByCodes находит товары справочника по кодам 1С (формат справочника, model.NormalizeGoodCode).
//
// Что: код → товар. Зачем: сопоставление строк «Реестра» на сборку (P9-01) — одним запросом на
// весь файл, а не запросом на строку (в реестре за день ~900 строк). Как: `code = ANY($1)` по
// индексу goods_code_idx; код в goods уникален (ON CONFLICT (code) у Upsert). Признак
// is_active не фильтруется: код — идентичность товара, а неактивный товар может лежать на
// складе. Кодов, которых нет в справочнике, в ответе нет.
func (r *GoodsRepository) ByCodes(ctx context.Context, codes []string) (map[string]model.RegistryGood, error) {
	out := make(map[string]model.RegistryGood, len(codes))
	if len(codes) == 0 {
		return out, nil
	}
	rows, err := r.pool.Query(ctx, `
		SELECT id::text, code, name, cz_marked
		FROM goods
		WHERE code = ANY($1)`, codes)
	if err != nil {
		return nil, fmt.Errorf("goods by codes: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var g model.RegistryGood
		if err := rows.Scan(&g.ID, &g.Code, &g.Name, &g.CZMarked); err != nil {
			return nil, fmt.Errorf("scan good: %w", err)
		}
		out[g.Code] = g
	}
	return out, rows.Err()
}
