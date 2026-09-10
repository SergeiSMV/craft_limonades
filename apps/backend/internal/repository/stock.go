package repository

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/shopspring/decimal"

	"craftwms/internal/model"
)

// ErrInsufficientStock — попытка списать больше, чем есть в (ячейка, товар, партия).
var ErrInsufficientStock = errors.New("insufficient stock")

// StockRepository — доступ к таблице stock (ядро учёта остатков).
type StockRepository struct {
	pool *pgxpool.Pool
}

// NewStockRepository создаёт репозиторий остатков.
func NewStockRepository(pool *pgxpool.Pool) *StockRepository {
	return &StockRepository{pool: pool}
}

// Add — приход: увеличить остаток по грани на qty. Атомарный upsert: если строки нет —
// создаём, если есть — прибавляем. Гонок нет: инкремент делается одним SQL-стейтментом,
// конфликт разрешает БД по UNIQUE(cell_id, good_id, batch_id).
func (r *StockRepository) Add(ctx context.Context, key model.StockKey, qty decimal.Decimal) error {
	return addStock(ctx, r.pool, key, qty)
}

// Set — установить остаток по грани в ТОЧНОЕ значение qty (SET, не приращение). Атомарный upsert:
// нет строки — создаём, есть — перезаписываем qty одним стейтментом. Нужен вводу остатков
// (P-FastStart): «в ячейке ровно столько». Отрицательное отсечёт CHECK(qty>=0) в БД (страховка
// к валидации сервиса); ноль допустим — строка остаётся с qty=0 (нулевые не удаляем).
func (r *StockRepository) Set(ctx context.Context, key model.StockKey, qty decimal.Decimal) error {
	return setStock(ctx, r.pool, key, qty)
}

// Remove — расход: уменьшить остаток по грани на qty. Атомарно и безопасно:
// UPDATE с условием qty >= $ не тронет строку, если списывать нечем → ErrInsufficientStock.
// Два параллельных списания не уведут остаток в минус (проверка и вычитание — в одном стейтменте).
func (r *StockRepository) Remove(ctx context.Context, key model.StockKey, qty decimal.Decimal) error {
	return removeStock(ctx, r.pool, key, qty)
}

// Transfer — перенести qty между ячейками (расход из from + приход в to) в ОДНОЙ транзакции.
// Примитив для размещения/перемещения (P5/P6). Если расхода не хватило — вся транзакция
// откатывается, приход не применяется.
func (r *StockRepository) Transfer(ctx context.Context, from, to model.StockKey, qty decimal.Decimal) error {
	return WithinTx(ctx, r.pool, func(q Querier) error {
		if err := removeStock(ctx, q, from, qty); err != nil {
			return err
		}
		return addStock(ctx, q, to, qty)
	})
}

// GetQty — текущее количество по грани. Нет строки → 0 (остатка нет), это не ошибка.
func (r *StockRepository) GetQty(ctx context.Context, key model.StockKey) (decimal.Decimal, error) {
	if err := guardStockKey(key); err != nil {
		return decimal.Zero, err
	}
	var s string
	// qty::text — чтобы numeric пришёл точной строкой и разобрался в decimal без потерь.
	err := r.pool.QueryRow(ctx,
		`SELECT qty::text FROM stock
		 WHERE cell_id = $1 AND good_id = $2 AND batch_id = $3 AND internal_warehouse_id = $4`,
		key.CellID, key.GoodID, key.BatchID, key.InternalWarehouseID,
	).Scan(&s)
	if errors.Is(err, pgx.ErrNoRows) {
		return decimal.Zero, nil
	}
	if err != nil {
		return decimal.Zero, fmt.Errorf("get stock qty: %w", err)
	}
	d, err := decimal.NewFromString(s)
	if err != nil {
		return decimal.Zero, fmt.Errorf("parse qty %q: %w", s, err)
	}
	return d, nil
}

// addStock/removeStock — низкоуровневые операции, принимают Querier (пул или tx),
// чтобы их можно было композировать в транзакции (Transfer). qty передаём строкой
// и приводим $4::numeric — надёжно для numeric-колонки без завязки на кодирование типов.

// ErrEmptyInternalWarehouse — в ключе остатка не задана учётная принадлежность.
//
// Отдельная ошибка, а не отказ БД: пустая строка доходит до запроса и падает невнятным
// «invalid input syntax for type uuid», по которому непонятно, что именно забыли. Поле добавилось
// к StockKey уже после того, как операции остатка разошлись по коду, и компилятор такие места
// не подсвечивает — литерал структуры с именованными полями собирается и без него.
var ErrEmptyInternalWarehouse = errors.New("internal warehouse is required in stock key")

// guardStockKey проверяет, что ключ остатка полон.
func guardStockKey(key model.StockKey) error {
	if key.InternalWarehouseID == "" {
		return ErrEmptyInternalWarehouse
	}
	return nil
}

func addStock(ctx context.Context, q Querier, key model.StockKey, qty decimal.Decimal) error {
	if err := guardStockKey(key); err != nil {
		return err
	}
	_, err := q.Exec(ctx, `
		INSERT INTO stock (cell_id, good_id, batch_id, internal_warehouse_id, qty)
		VALUES ($1, $2, $3, $5, $4::numeric)
		ON CONFLICT (cell_id, good_id, batch_id, internal_warehouse_id)
		DO UPDATE SET qty = stock.qty + EXCLUDED.qty`,
		key.CellID, key.GoodID, key.BatchID, qty.String(), key.InternalWarehouseID)
	if err != nil {
		return fmt.Errorf("add stock: %w", err)
	}
	return nil
}

func setStock(ctx context.Context, q Querier, key model.StockKey, qty decimal.Decimal) error {
	if err := guardStockKey(key); err != nil {
		return err
	}
	_, err := q.Exec(ctx, `
		INSERT INTO stock (cell_id, good_id, batch_id, internal_warehouse_id, qty)
		VALUES ($1, $2, $3, $5, $4::numeric)
		ON CONFLICT (cell_id, good_id, batch_id, internal_warehouse_id)
		DO UPDATE SET qty = EXCLUDED.qty`,
		key.CellID, key.GoodID, key.BatchID, qty.String(), key.InternalWarehouseID)
	if err != nil {
		return fmt.Errorf("set stock: %w", err)
	}
	return nil
}

func removeStock(ctx context.Context, q Querier, key model.StockKey, qty decimal.Decimal) error {
	if err := guardStockKey(key); err != nil {
		return err
	}
	tag, err := q.Exec(ctx, `
		UPDATE stock SET qty = qty - $4::numeric
		WHERE cell_id = $1 AND good_id = $2 AND batch_id = $3 AND internal_warehouse_id = $5
		  AND qty >= $4::numeric`,
		key.CellID, key.GoodID, key.BatchID, qty.String(), key.InternalWarehouseID)
	if err != nil {
		return fmt.Errorf("remove stock: %w", err)
	}
	// 0 затронутых строк = строки нет ИЛИ остатка не хватило → недостаточно остатка.
	if tag.RowsAffected() == 0 {
		return ErrInsufficientStock
	}
	return nil
}

// ErrNoDefaultInternalWarehouse — в справочнике нет склада по умолчанию. Заводить остаток
// «куда-нибудь» нельзя: учётная принадлежность — часть грани, и ошибка здесь тихо исказит учёт.
var ErrNoDefaultInternalWarehouse = errors.New("no default internal warehouse")

// defaultInternalWarehouse — внутренний склад, куда приходуем, если он не выбран явно.
//
// Ищется по ФЛАГУ, а не по коду: справочник пополняется из интерфейса, склад можно переименовать
// или заменить другим, и зашитый в код 'MAIN' сделал бы такое переименование поломкой.
// Значение не кешируется — справочник живой, а вызов происходит раз на операцию, не в цикле.
func defaultInternalWarehouse(ctx context.Context, q Querier) (string, error) {
	var id string
	err := q.QueryRow(ctx, `SELECT id::text FROM internal_warehouses WHERE is_default`).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", ErrNoDefaultInternalWarehouse
	}
	if err != nil {
		return "", fmt.Errorf("склад по умолчанию: %w", err)
	}
	return id, nil
}
