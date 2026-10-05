package repository

import (
	"context"
	"fmt"

	"craftwms/internal/movement"
)

// LoadUnitContents — состав грузовых единиц для разворота движений (P4-09-1).
//
// Работает на переданном Querier, а не на пуле: состав обязан читаться внутри транзакции
// операции — так разворот видит ровно то, что переехало, а не то, что лежит в коробе потом.
type LoadUnitContents struct {
	q Querier
}

// NewLoadUnitContents создаёт источник состава ГЕ на пуле или транзакции.
func NewLoadUnitContents(q Querier) *LoadUnitContents {
	return &LoadUnitContents{q: q}
}

// Проверка на этапе компиляции: репозиторий подходит разворачивающему домену.
var _ movement.ContentReader = (*LoadUnitContents)(nil)

// Contents возвращает состав каждой запрошенной ГЕ вместе с вложенными (паллета — это всё,
// что в её коробах). Ключ есть у каждой существующей ГЕ, даже пустой; несуществующей ГЕ
// в ответе нет — так домен отличает «пусто» от «нет такой».
//
// Как: рекурсивный обход дерева по parent_id от каждой запрошенной ГЕ («корня»), затем
// состав всех узлов дерева, сложенный по товару и партии внутри корня.
//
// ⚠ UNION, а не UNION ALL: схема запрещает ГЕ быть родителем самой себе, но не цикл через
// две ГЕ (A в B, B в A). С UNION ALL такой цикл крутил бы рекурсию бесконечно; UNION
// отбрасывает уже пройденную пару (корень, узел), и обход завершается. Вложенность в пилоте
// не используется, но схема её допускает, и зависший запрос держал бы транзакцию операции.
func (r *LoadUnitContents) Contents(ctx context.Context, loadUnitIDs []string) (map[string][]movement.ContentLine, error) {
	out := make(map[string][]movement.ContentLine, len(loadUnitIDs))
	if len(loadUnitIDs) == 0 {
		return out, nil
	}
	rows, err := r.q.Query(ctx, `
		WITH RECURSIVE tree (root, node) AS (
			SELECT id, id FROM load_units WHERE id = ANY($1::text[]::uuid[])
			UNION
			SELECT t.root, lu.id FROM load_units lu JOIN tree t ON lu.parent_id = t.node
		)
		SELECT t.root::text, c.good_id::text, c.batch_id::text, sum(c.qty)::text
		FROM tree t
		LEFT JOIN lu_content c ON c.load_unit_id = t.node
		GROUP BY t.root, c.good_id, c.batch_id
		ORDER BY t.root, min(c.created_at), c.good_id, c.batch_id`, loadUnitIDs)
	if err != nil {
		return nil, fmt.Errorf("состав ГЕ: %w", err)
	}
	defer rows.Close()

	for rows.Next() {
		var root string
		var good, batch, qty *string
		if err := rows.Scan(&root, &good, &batch, &qty); err != nil {
			return nil, fmt.Errorf("разбор состава ГЕ: %w", err)
		}
		if _, ok := out[root]; !ok {
			out[root] = []movement.ContentLine{}
		}
		// Пустая ГЕ даёт строку с NULL из LEFT JOIN: сама ГЕ есть, позиций нет.
		if good == nil {
			continue
		}
		q, err := parseQty(*qty)
		if err != nil {
			return nil, err
		}
		out[root] = append(out[root], movement.ContentLine{GoodID: *good, BatchID: *batch, Qty: q})
	}
	return out, rows.Err()
}
