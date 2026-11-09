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
// login и username nullable → COALESCE к ” (пусто = отсутствует), чтобы скан шёл в string.
// Должность и её права — тем же запросом (ADHOC-49): права проверяются по ним.
const userColumns = `u.id::text AS id, COALESCE(u.login,'') AS login, COALESCE(u.username,'') AS username,
	u.password_hash, u.full_name, u.position_id::text AS position_id, p.name AS position_name,
	p.is_system AS position_system, p.rights AS position_rights, u.badge_secret_enc, u.is_active,
	u.created_at, u.updated_at`

const userFrom = ` FROM users u JOIN positions p ON p.id = u.position_id`

// GetByLogin возвращает пользователя по логину (первые 8 цифр бейджа).
func (r *UserRepository) GetByLogin(ctx context.Context, login string) (model.User, error) {
	rows, err := r.pool.Query(ctx, `SELECT `+userColumns+userFrom+` WHERE u.login = $1`, login)
	if err != nil {
		return model.User{}, fmt.Errorf("query user by login: %w", err)
	}
	return collectUser(rows)
}

// GetByUsername возвращает пользователя по username (вход по логину/паролю, P1-01-1).
func (r *UserRepository) GetByUsername(ctx context.Context, username string) (model.User, error) {
	rows, err := r.pool.Query(ctx, `SELECT `+userColumns+userFrom+` WHERE u.username = $1`, username)
	if err != nil {
		return model.User{}, fmt.Errorf("query user by username: %w", err)
	}
	return collectUser(rows)
}

// GetByID возвращает пользователя по id (uuid как текст).
func (r *UserRepository) GetByID(ctx context.Context, id string) (model.User, error) {
	rows, err := r.pool.Query(ctx, `SELECT `+userColumns+userFrom+` WHERE u.id = $1::uuid`, id)
	if err != nil {
		return model.User{}, fmt.Errorf("query user by id: %w", err)
	}
	return collectUser(rows)
}

// SaveBadgeSecret запоминает зашифрованный секрет бейджа (ADHOC-65) — после входа по нему.
// Только у той же строки с тем же логином: бейдж за время входа могли сменить в портале.
func (r *UserRepository) SaveBadgeSecret(ctx context.Context, id, login string, sealed []byte) error {
	if _, err := r.pool.Exec(ctx, `
		UPDATE users SET badge_secret_enc = $3
		WHERE id = $1::uuid AND login = $2`, id, login, sealed); err != nil {
		return fmt.Errorf("запомнить номер бейджа: %w", err)
	}
	return nil
}

// UserAccess — доступ пользователя (ADHOC-49): действующие права, системная ли должность,
// активен ли. Его проверяет middleware на каждой ручке с правом — из базы на каждый запрос, а
// не из токена: смена должности и блокировка действуют сразу. Нет пользователя — неактивен.
func (r *UserRepository) UserAccess(ctx context.Context, userID string) (model.Access, error) {
	var a model.Access
	var rights []string
	err := r.pool.QueryRow(ctx, `
		SELECT p.is_system, p.rights, u.is_active
		FROM users u JOIN positions p ON p.id = u.position_id
		WHERE u.id = $1::uuid`, userID).Scan(&a.System, &rights, &a.Active)
	if errors.Is(err, pgx.ErrNoRows) {
		return model.Access{}, nil
	}
	if err != nil {
		return model.Access{}, fmt.Errorf("права пользователя: %w", err)
	}
	a.Rights = model.UserRights(a.System, rights)
	return a, nil
}

// CreateAdminIfNotExists создаёт админа (должность «Администратор»), если логина ещё нет. Идемпотентно.
// Возвращает created=true, если строка была вставлена; false — если логин уже существовал.
func (r *UserRepository) CreateAdminIfNotExists(ctx context.Context, login, passwordHash, fullName string) (bool, error) {
	// ON CONFLICT DO NOTHING RETURNING id: при конфликте строк не вернётся → created=false.
	rows, err := r.pool.Query(ctx, `
		INSERT INTO users (login, password_hash, full_name, position_id, is_active)
		VALUES ($1, $2, $3, $4::uuid, true)
		ON CONFLICT (login) DO NOTHING
		RETURNING id`, login, passwordHash, fullName, model.PositionAdminID)
	if err != nil {
		return false, fmt.Errorf("insert admin: %w", err)
	}
	defer rows.Close()
	created := rows.Next()
	return created, rows.Err()
}

// CreateUsernameAdminIfNotExists создаёт admin с входом по username/паролю (без бейджа).
// Идемпотентно: при существующем username строку не вставляет. created=true — если вставили.
func (r *UserRepository) CreateUsernameAdminIfNotExists(ctx context.Context, username, passwordHash, fullName string) (bool, error) {
	// login=NULL (у admin бейджа нет); XOR-констрейнт схемы это допускает.
	rows, err := r.pool.Query(ctx, `
		INSERT INTO users (username, password_hash, full_name, position_id, is_active)
		VALUES ($1, $2, $3, $4::uuid, true)
		ON CONFLICT (username) DO NOTHING
		RETURNING id`, username, passwordHash, fullName, model.PositionAdminID)
	if err != nil {
		return false, fmt.Errorf("insert username admin: %w", err)
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
