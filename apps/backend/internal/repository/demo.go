package repository

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/golang-migrate/migrate/v4"
	_ "github.com/golang-migrate/migrate/v4/database/pgx/v5" // драйвер миграций, схема pgx5://
	"github.com/golang-migrate/migrate/v4/source/iofs"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"craftwms/internal/model"
	"craftwms/migrations"
)

// DemoRepository - база демо-сервера (ADHOC-67): проверка, что это действительно демо-база,
// пересоздание схемы и сведения о последнем сбросе.
//
// Зачем отдельный репозиторий: сброс стирает базу целиком, и всё опасное собрано в одном месте
// за одной проверкой имени базы ([DemoRepository.IsDemoDatabase]).
type DemoRepository struct {
	pool *pgxpool.Pool
	dsn  string // DSN приложения: миграциям нужно своё подключение
}

// NewDemoRepository - репозиторий демо-базы поверх пула приложения и его DSN.
func NewDemoRepository(pool *pgxpool.Pool, dsn string) *DemoRepository {
	return &DemoRepository{pool: pool, dsn: dsn}
}

// IsDemoDatabase - имя текущей базы оканчивается на «_demo».
//
// Это вторая защита после DEMO_MODE: боевая база так не называется, и переменная, по ошибке
// заданная на проде, не откроет вход без пароля и не сотрёт данные.
func (r *DemoRepository) IsDemoDatabase(ctx context.Context) (string, bool, error) {
	var name string
	if err := r.pool.QueryRow(ctx, `SELECT current_database()`).Scan(&name); err != nil {
		return "", false, fmt.Errorf("имя базы: %w", err)
	}
	return name, strings.HasSuffix(name, model.DemoDatabaseSuffix), nil
}

// RecreateSchema стирает схему public и накатывает все миграции заново - база становится
// такой же, как после первого развёртывания.
//
// Как: DROP SCHEMA … CASCADE + CREATE SCHEMA, затем golang-migrate из миграций, встроенных в
// бинарь (те же, что катит `migrate up` при обновлении). После этого пул сбрасывается: у старых
// соединений в кэше лежат подготовленные запросы к удалённым таблицам.
func (r *DemoRepository) RecreateSchema(ctx context.Context) error {
	if _, ok, err := r.IsDemoDatabase(ctx); err != nil {
		return err
	} else if !ok {
		return model.ErrDemoNotDemoDatabase
	}
	if _, err := r.pool.Exec(ctx, `DROP SCHEMA public CASCADE; CREATE SCHEMA public;`); err != nil {
		return fmt.Errorf("пересоздание схемы: %w", err)
	}
	r.pool.Reset()

	src, err := iofs.New(migrations.FS, ".")
	if err != nil {
		return fmt.Errorf("источник миграций: %w", err)
	}
	dsn := strings.Replace(r.dsn, "postgresql://", "pgx5://", 1)
	dsn = strings.Replace(dsn, "postgres://", "pgx5://", 1)
	m, err := migrate.NewWithSourceInstance("iofs", src, dsn)
	if err != nil {
		return fmt.Errorf("инициализация миграций: %w", err)
	}
	defer func() { _, _ = m.Close() }()
	if err := m.Up(); err != nil && !errors.Is(err, migrate.ErrNoChange) {
		return fmt.Errorf("миграции: %w", err)
	}
	return nil
}

// SeededAt - когда включён демо-пользователь, то есть когда база последний раз заполнена;
// ok=false - демо-данных нет (свежая база или сброс оборвался).
func (r *DemoRepository) SeededAt(ctx context.Context) (time.Time, bool, error) {
	var at time.Time
	err := r.pool.QueryRow(ctx, `SELECT created_at FROM users WHERE login = $1 AND is_active`, model.DemoUserLogin).Scan(&at)
	if errors.Is(err, pgx.ErrNoRows) {
		return time.Time{}, false, nil
	}
	if err != nil {
		return time.Time{}, false, fmt.Errorf("демо-пользователь: %w", err)
	}
	return at, true, nil
}
