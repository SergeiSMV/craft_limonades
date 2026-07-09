// Package repository — слой доступа к данным (Postgres). Изолирует SQL от домена.
// Здесь же — конструктор пула соединений; конкретные репозитории (users и т.д.) добавятся позже.
package repository

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

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

	cfg.MaxConns = 10             // потолок соединений в пуле
	cfg.MaxConnLifetime = time.Hour // периодически пересоздаём коннекты

	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("создание пула: %w", err)
	}
	return pool, nil
}
