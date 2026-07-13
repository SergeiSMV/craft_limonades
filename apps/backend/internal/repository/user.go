package repository

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"craftwms/internal/model"
)

// ErrUserNotFound — пользователь не найден по логину/id.
var ErrUserNotFound = errors.New("user not found")

// UserRepository — доступ к таблице users. Изолирует SQL от домена.
type UserRepository struct {
	pool *pgxpool.Pool
}

// NewUserRepository создаёт репозиторий пользователей.
func NewUserRepository(pool *pgxpool.Pool) *UserRepository {
	return &UserRepository{pool: pool}
}

// колонки в фиксированном порядке; id приводим к тексту (id::text), чтобы скан шёл в string.
const userColumns = `id::text AS id, login, password_hash, full_name, role, is_active, created_at, updated_at`

// GetByLogin возвращает пользователя по логину (первые 8 цифр бейджа).
func (r *UserRepository) GetByLogin(ctx context.Context, login string) (model.User, error) {
	rows, err := r.pool.Query(ctx, `SELECT `+userColumns+` FROM users WHERE login = $1`, login)
	if err != nil {
		return model.User{}, fmt.Errorf("query user by login: %w", err)
	}
	return collectUser(rows)
}

// GetByID возвращает пользователя по id (uuid как текст).
func (r *UserRepository) GetByID(ctx context.Context, id string) (model.User, error) {
	rows, err := r.pool.Query(ctx, `SELECT `+userColumns+` FROM users WHERE id = $1::uuid`, id)
	if err != nil {
		return model.User{}, fmt.Errorf("query user by id: %w", err)
	}
	return collectUser(rows)
}

// CreateAdminIfNotExists создаёт админа, если логина ещё нет. Идемпотентно.
// Возвращает created=true, если строка была вставлена; false — если логин уже существовал.
func (r *UserRepository) CreateAdminIfNotExists(ctx context.Context, login, passwordHash, fullName string) (bool, error) {
	// ON CONFLICT DO NOTHING RETURNING id: при конфликте строк не вернётся → created=false.
	rows, err := r.pool.Query(ctx, `
		INSERT INTO users (login, password_hash, full_name, role, is_active)
		VALUES ($1, $2, $3, 'admin', true)
		ON CONFLICT (login) DO NOTHING
		RETURNING id`, login, passwordHash, fullName)
	if err != nil {
		return false, fmt.Errorf("insert admin: %w", err)
	}
	defer rows.Close()
	created := rows.Next()
	return created, rows.Err()
}

// collectUser разбирает ровно одну строку в model.User; отсутствие строки → ErrUserNotFound.
func collectUser(rows pgx.Rows) (model.User, error) {
	user, err := pgx.CollectExactlyOneRow(rows, pgx.RowToStructByName[model.User])
	if errors.Is(err, pgx.ErrNoRows) {
		return model.User{}, ErrUserNotFound
	}
	if err != nil {
		return model.User{}, fmt.Errorf("scan user: %w", err)
	}
	return user, nil
}
