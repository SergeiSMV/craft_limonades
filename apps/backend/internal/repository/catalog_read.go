package repository

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/shopspring/decimal"

	"craftwms/internal/model"
)

// catalog_read.go — операции ЧТЕНИЯ справочников (P1-06): список/поиск/фильтры/пагинация.
// Total считаем окном COUNT(*) OVER() в том же запросе — одна поездка в БД вместо двух.
// Пустые списки возвращаем как непустой слайс (не nil) — чтобы в JSON был [], а не null.

// ErrNotFound — сущность по id не найдена (для точечного чтения).
var ErrNotFound = errors.New("not found")

// --- Товары (goods) ---

// GoodsFilter — параметры выборки товаров. Пустые поля = без фильтра.
type GoodsFilter struct {
	Words      []string // слова поиска: каждое должно встретиться в name/code/full_name
	GroupID    *string  // фильтр по группе
	SupplierID *string  // фильтр по поставщику
	Limit      int
	Offset     int
}

// List возвращает товары с присоединёнными именами группы/поставщика + общее число под фильтр.
//
// Поиск — «все слова присутствуют, порядок не важен»: NOT EXISTS отсекает товар, у которого
// хоть одно слово не встретилось. Ищем по склейке name+code+full_name, обе стороны сравнения
// нормализованы (нижний регистр, «ё»→«е»); слова приходят уже нормализованными из сервиса.
// LIKE по подстроке индекс не использует — на текущем каталоге (сотни позиций) это неважно;
// при росте до десятков тысяч лечится расширением pg_trgm и GIN-индексом.
//
// Фильтр по группе — по ПОДДЕРЕВУ: товар привязан к самой глубокой группе своего пути (листу),
// поэтому выбор родительской группы («Матрица …», «-Товары/…») должен вернуть товары всех её
// подгрупп. Рекурсивный CTE собирает выбранную группу + всех потомков; при $2 IS NULL фильтр не применяется.
func (r *GoodsRepository) List(ctx context.Context, f GoodsFilter) ([]model.Good, int, error) {
	rows, err := r.pool.Query(ctx, `
		WITH RECURSIVE group_subtree AS (
			SELECT id FROM nomenclature_groups WHERE $2::uuid IS NOT NULL AND id = $2::uuid
			UNION ALL
			SELECT ng.id FROM nomenclature_groups ng
			JOIN group_subtree gs ON ng.parent_id = gs.id
		)
		SELECT g.id::text, g.code, g.name, g.full_name, g.uom,
		       g.group_id::text, ng.name, g.supplier_id::text, s.name, g.is_active,
		       COUNT(*) OVER() AS total
		FROM goods g
		LEFT JOIN nomenclature_groups ng ON ng.id = g.group_id
		LEFT JOIN suppliers s           ON s.id = g.supplier_id
		WHERE (cardinality($1::text[]) = 0 OR NOT EXISTS (
		        SELECT 1 FROM unnest($1::text[]) AS w
		        WHERE replace(lower(g.name || ' ' || coalesce(g.code, '') || ' ' || coalesce(g.full_name, '')), 'ё', 'е')
		              NOT LIKE '%' || w || '%'
		      ))
		  AND ($2::uuid IS NULL OR g.group_id IN (SELECT id FROM group_subtree))
		  AND ($3::uuid IS NULL OR g.supplier_id = $3::uuid)
		ORDER BY g.name
		LIMIT $4 OFFSET $5`,
		f.Words, f.GroupID, f.SupplierID, f.Limit, f.Offset)
	if err != nil {
		return nil, 0, fmt.Errorf("list goods: %w", err)
	}
	defer rows.Close()

	items := make([]model.Good, 0)
	total := 0
	for rows.Next() {
		var g model.Good
		if err := rows.Scan(&g.ID, &g.Code, &g.Name, &g.FullName, &g.UOM,
			&g.GroupID, &g.GroupName, &g.SupplierID, &g.SupplierName, &g.IsActive, &total); err != nil {
			return nil, 0, fmt.Errorf("scan good: %w", err)
		}
		items = append(items, g)
	}
	return items, total, rows.Err()
}

// GetByID возвращает один товар (с именами группы/поставщика) или ErrNotFound.
func (r *GoodsRepository) GetByID(ctx context.Context, id string) (model.Good, error) {
	var g model.Good
	err := r.pool.QueryRow(ctx, `
		SELECT g.id::text, g.code, g.name, g.full_name, g.uom,
		       g.group_id::text, ng.name, g.supplier_id::text, s.name, g.is_active
		FROM goods g
		LEFT JOIN nomenclature_groups ng ON ng.id = g.group_id
		LEFT JOIN suppliers s           ON s.id = g.supplier_id
		WHERE g.id = $1::uuid`, id).
		Scan(&g.ID, &g.Code, &g.Name, &g.FullName, &g.UOM,
			&g.GroupID, &g.GroupName, &g.SupplierID, &g.SupplierName, &g.IsActive)
	if errors.Is(err, pgx.ErrNoRows) {
		return model.Good{}, ErrNotFound
	}
	if err != nil {
		return model.Good{}, fmt.Errorf("get good %q: %w", id, err)
	}
	return g, nil
}

// --- Группы номенклатуры ---

// List возвращает все группы (справочник небольшой — без пагинации; клиент строит дерево по parent_id).
func (r *NomenclatureGroupRepository) List(ctx context.Context) ([]model.NomenclatureGroup, error) {
	rows, err := r.pool.Query(ctx, `
		SELECT id::text, code, name, parent_id::text
		FROM nomenclature_groups ORDER BY name`)
	if err != nil {
		return nil, fmt.Errorf("list groups: %w", err)
	}
	defer rows.Close()

	items := make([]model.NomenclatureGroup, 0)
	for rows.Next() {
		var g model.NomenclatureGroup
		if err := rows.Scan(&g.ID, &g.Code, &g.Name, &g.ParentID); err != nil {
			return nil, fmt.Errorf("scan group: %w", err)
		}
		items = append(items, g)
	}
	return items, rows.Err()
}

// --- Поставщики ---

// List возвращает поставщиков (справочник небольшой — без пагинации), опционально фильтруя по подстроке имени.
func (r *SupplierRepository) List(ctx context.Context, query string) ([]model.Supplier, error) {
	rows, err := r.pool.Query(ctx, `
		SELECT id::text, name FROM suppliers
		WHERE ($1 = '' OR name ILIKE '%' || $1 || '%')
		ORDER BY name`, query)
	if err != nil {
		return nil, fmt.Errorf("list suppliers: %w", err)
	}
	defer rows.Close()

	items := make([]model.Supplier, 0)
	for rows.Next() {
		var s model.Supplier
		if err := rows.Scan(&s.ID, &s.Name); err != nil {
			return nil, fmt.Errorf("scan supplier: %w", err)
		}
		items = append(items, s)
	}
	return items, rows.Err()
}

// --- Ячейки ---

// CellsFilter — параметры выборки ячеек. Пустые поля = без фильтра.
type CellsFilter struct {
	Query       string  // подстрока по адресу (ILIKE)
	WarehouseID *string // фильтр по складу
	IsFloor     *bool   // фильтр по признаку напольной
	Limit       int
	Offset      int
}

// List возвращает ячейки под фильтр + общее число.
func (r *CellRepository) List(ctx context.Context, f CellsFilter) ([]model.Cell, int, error) {
	rows, err := r.pool.Query(ctx, `
		SELECT id::text, warehouse_id::text, address, type, is_floor, is_active, is_default,
		       COUNT(*) OVER() AS total
		FROM cells
		WHERE ($1 = '' OR address ILIKE '%' || $1 || '%')
		  AND ($2::uuid IS NULL OR warehouse_id = $2::uuid)
		  AND ($3::boolean IS NULL OR is_floor = $3::boolean)
		ORDER BY address
		LIMIT $4 OFFSET $5`,
		f.Query, f.WarehouseID, f.IsFloor, f.Limit, f.Offset)
	if err != nil {
		return nil, 0, fmt.Errorf("list cells: %w", err)
	}
	defer rows.Close()

	items := make([]model.Cell, 0)
	total := 0
	for rows.Next() {
		var c model.Cell
		if err := rows.Scan(&c.ID, &c.WarehouseID, &c.Address, &c.Type, &c.IsFloor, &c.IsActive, &c.IsDefault, &total); err != nil {
			return nil, 0, fmt.Errorf("scan cell: %w", err)
		}
		items = append(items, c)
	}
	return items, total, rows.Err()
}

// --- Остатки (товарный разрез) ---

// StockFilter — параметры выборки остатков. Пустые поля = без фильтра.
type StockFilter struct {
	GoodID *string // «где лежит товар X»
	CellID *string // «что лежит в ячейке Y»
	Limit  int
	Offset int
}

// List возвращает остатки с адресом ячейки и датой партии + общее число.
// qty::text — чтобы numeric пришёл точной строкой и разобрался в decimal без потерь.
//
// Нулевые строки не отдаются (ADHOC-21): расход уменьшает строку остатка, а не удаляет её,
// и после размещения, пересчёта в ноль, перемещения или списания в таблице остаётся
// «партия · ячейка · 0». Для «где лежит товар» это ложь — товара там нет. Фильтр на чтении,
// а не удаление при расходе: так закрыты все пути к нулю разом, включая будущие.
func (r *StockRepository) List(ctx context.Context, f StockFilter) ([]model.StockItem, int, error) {
	rows, err := r.pool.Query(ctx, `
		SELECT s.cell_id::text, c.address, s.good_id::text, s.batch_id::text,
		       b.production_date::text, s.qty::text,
		       s.internal_warehouse_id::text, w.code, w.name, w.is_default,
		       COUNT(*) OVER() AS total
		FROM stock s
		JOIN cells   c ON c.id = s.cell_id
		JOIN batches b ON b.id = s.batch_id
		JOIN internal_warehouses w ON w.id = s.internal_warehouse_id
		WHERE s.qty > 0
		  AND ($1::uuid IS NULL OR s.good_id = $1::uuid)
		  AND ($2::uuid IS NULL OR s.cell_id = $2::uuid)
		-- Внутри ячейки сортируем по складу, чтобы «основной» и «брак» шли рядом и в одном
		-- порядке от запроса к запросу.
		ORDER BY c.address, b.production_date, w.code
		LIMIT $3 OFFSET $4`,
		f.GoodID, f.CellID, f.Limit, f.Offset)
	if err != nil {
		return nil, 0, fmt.Errorf("list stock: %w", err)
	}
	defer rows.Close()

	items := make([]model.StockItem, 0)
	total := 0
	for rows.Next() {
		var it model.StockItem
		var qtyStr string
		if err := rows.Scan(&it.CellID, &it.CellAddress, &it.GoodID, &it.BatchID,
			&it.ProductionDate, &qtyStr,
			&it.InternalWarehouseID, &it.InternalWarehouseCode, &it.InternalWarehouseName,
			&it.InternalWarehouseIsDefault, &total); err != nil {
			return nil, 0, fmt.Errorf("scan stock item: %w", err)
		}
		q, err := decimal.NewFromString(qtyStr)
		if err != nil {
			return nil, 0, fmt.Errorf("parse qty %q: %w", qtyStr, err)
		}
		it.Qty = q
		items = append(items, it)
	}
	return items, total, rows.Err()
}
