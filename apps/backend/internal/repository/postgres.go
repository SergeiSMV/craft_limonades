// Package repository — слой доступа к данным (Postgres). Изолирует SQL от домена.
// Здесь же — конструктор пула соединений; конкретные репозитории (users и т.д.) добавятся позже.
package repository

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Querier — общий контракт исполнителя запросов. Его реализуют и *pgxpool.Pool,
// и pgx.Tx, поэтому репозитории могут работать как напрямую через пул, так и внутри
// транзакции (для атомарной композиции нескольких операций — см. WithinTx).
type Querier interface {
	Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error)
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
}

// WithinTx выполняет fn в транзакции: BEGIN → fn(tx) → COMMIT; при ошибке fn — ROLLBACK.
// Зачем: несколько движений остатка (например, перенос = расход+приход) должны применяться
// «всё или ничего», иначе при сбое между ними остаток разъедется.
func WithinTx(ctx context.Context, pool *pgxpool.Pool, fn func(Querier) error) error {
	tx, err := pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("begin tx: %w", err)
	}
	if err := fn(tx); err != nil {
		_ = tx.Rollback(ctx) // ошибку отката не маскируем исходной; исходная важнее
		return err
	}
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("commit tx: %w", err)
	}
	return nil
}

// NewPool создаёт пул соединений к Postgres по DSN.
//
// Что: пул переиспользуемых коннектов к БД.
// Зачем: не открывать новое подключение на каждый запрос — это дорого.
// Как: pgxpool.ParseConfig разбирает DSN, задаём разумные лимиты пула; реальные
// соединения устанавливаются лениво (при первом обращении), поэтому вызов не падает,
// если БД временно недоступна — проверять доступность нужно отдельным Ping.
func NewPool(ctx context.Context, dsn string) (*pgxpool.Pool, error) {
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		return nil, fmt.Errorf("разбор DSN: %w", err)
	}

	cfg.MaxConns = 10               // потолок соединений в пуле
	cfg.MaxConnLifetime = time.Hour // периодически пересоздаём коннекты

	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("создание пула: %w", err)
	}
	return pool, nil
}
