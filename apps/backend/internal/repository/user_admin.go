package repository

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"craftwms/internal/model"
)

// UserAdminRepository — пользователи и должности для портала (ADHOC-49).
//
// Все правки — в транзакции под одной рекомендательной блокировкой: две правки администраторов
// параллельно не оставят систему без управления, проверив «кто ещё остался» каждая до другой.
// Каждая правка пишется в audit_log; хеши, бейджи и пароли в журнал не попадают.
type UserAdminRepository struct {
	pool *pgxpool.Pool
}

// NewUserAdminRepository создаёт репозиторий пользователей и должностей.
func NewUserAdminRepository(pool *pgxpool.Pool) *UserAdminRepository {
	return &UserAdminRepository{pool: pool}
}

// userAdminLockKey — ключ рекомендательной блокировки правок пользователей и должностей.
const userAdminLockKey = 1020

// Positions — должности: системная первой, дальше по названию; с числом пользователей.
func (r *UserAdminRepository) Positions(ctx context.Context) ([]model.Position, error) {
	rows, err := r.pool.Query(ctx, `
		SELECT p.id::text, p.name, p.rights, p.is_system, count(u.id)
		FROM positions p
		LEFT JOIN users u ON u.position_id = p.id
		GROUP BY p.id
		ORDER BY p.is_system DESC, p.name`)
	if err != nil {
		return nil, fmt.Errorf("должности: %w", err)
	}
	defer rows.Close()
	out := []model.Position{}
	for rows.Next() {
		var p model.Position
		var rights []string
		if err := rows.Scan(&p.ID, &p.Name, &rights, &p.IsSystem, &p.Users); err != nil {
			return nil, fmt.Errorf("разобрать должность: %w", err)
		}
		p.Rights = model.UserRights(p.IsSystem, rights)
		out = append(out, p)
	}
	return out, rows.Err()
}

// CreatePosition заводит должность; название занято — ErrPositionNameTaken.
func (r *UserAdminRepository) CreatePosition(ctx context.Context, in model.PositionInput, by string) (string, error) {
	var id string
	err := r.inTx(ctx, func(q Querier) error {
		if err := q.QueryRow(ctx, `INSERT INTO positions (name, rights) VALUES ($1, $2) RETURNING id::text`,
			in.Name, in.Rights).Scan(&id); err != nil {
			return positionError(err)
		}
		return audit(ctx, q, by, "position.create", "position", id, map[string]any{"name": in.Name, "rights": in.Rights})
	})
	return id, err
}

// UpdatePosition меняет название и права. Системную не меняет; правка, после которой ни у
// одного активного пользователя не осталось права «пользователи», откатывается.
func (r *UserAdminRepository) UpdatePosition(ctx context.Context, id string, in model.PositionInput, by string) error {
	return r.inTx(ctx, func(q Querier) error {
		if err := checkPositionEditable(ctx, q, id); err != nil {
			return err
		}
		if _, err := q.Exec(ctx, `UPDATE positions SET name = $2, rights = $3 WHERE id = $1::uuid`,
			id, in.Name, in.Rights); err != nil {
			return positionError(err)
		}
		if err := checkAdminsLeft(ctx, q); err != nil {
			return err
		}
		return audit(ctx, q, by, "position.update", "position", id, map[string]any{"name": in.Name, "rights": in.Rights})
	})
}

// DeletePosition удаляет должность без пользователей; системную — нет.
func (r *UserAdminRepository) DeletePosition(ctx context.Context, id, by string) error {
	return r.inTx(ctx, func(q Querier) error {
		if err := checkPositionEditable(ctx, q, id); err != nil {
			return err
		}
		var users int
		if err := q.QueryRow(ctx, `SELECT count(*) FROM users WHERE position_id = $1::uuid`, id).Scan(&users); err != nil {
			return fmt.Errorf("пользователи должности: %w", err)
		}
		if users > 0 {
			return model.ErrPositionInUse
		}
		var name string
		if err := q.QueryRow(ctx, `DELETE FROM positions WHERE id = $1::uuid RETURNING name`, id).Scan(&name); err != nil {
			return fmt.Errorf("удалить должность: %w", err)
		}
		return audit(ctx, q, by, "position.delete", "position", id, map[string]any{"name": name})
	})
}

// Users — все пользователи, активные сверху, по ФИО.
func (r *UserAdminRepository) Users(ctx context.Context) ([]model.UserListItem, error) {
	rows, err := r.pool.Query(ctx, `
		SELECT u.id::text, u.full_name, u.position_id::text, p.name, COALESCE(u.login, ''),
		       COALESCE(u.username, ''), u.is_active, u.created_at
		FROM users u JOIN positions p ON p.id = u.position_id
		ORDER BY u.is_active DESC, u.full_name`)
	if err != nil {
		return nil, fmt.Errorf("пользователи: %w", err)
	}
	defer rows.Close()
	out := []model.UserListItem{}
	for rows.Next() {
		var u model.UserListItem
		if err := rows.Scan(&u.ID, &u.FullName, &u.PositionID, &u.PositionName, &u.Login, &u.Username,
			&u.IsActive, &u.CreatedAt); err != nil {
			return nil, fmt.Errorf("разобрать пользователя: %w", err)
		}
		out = append(out, u)
	}
	return out, rows.Err()
}

// NewUser — пользователь к записи: вход уже разобран сервисом, секрет — хешем.
type NewUser struct {
	FullName, PositionID string
	Login, Username      string // ровно одно не пусто
	PasswordHash         string
	BadgeSecretEnc       []byte // зашифрованный секрет бейджа для печати (ADHOC-65); nil — нет
	By                   string
}

// CreateUser заводит пользователя. Бейдж или логин заняты — ErrBadgeTaken / ErrUsernameTaken.
func (r *UserAdminRepository) CreateUser(ctx context.Context, u NewUser) (string, error) {
	var id string
	err := r.inTx(ctx, func(q Querier) error {
		if err := checkPositionExists(ctx, q, u.PositionID); err != nil {
			return err
		}
		if err := q.QueryRow(ctx, `
			INSERT INTO users (login, username, password_hash, full_name, position_id, badge_secret_enc)
			VALUES (NULLIF($1, ''), NULLIF($2, ''), $3, $4, $5::uuid, $6)
			RETURNING id::text`, u.Login, u.Username, u.PasswordHash, u.FullName, u.PositionID,
			u.BadgeSecretEnc).Scan(&id); err != nil {
			return userError(err)
		}
		return audit(ctx, q, u.By, "user.create", "user", id, map[string]any{
			"full_name": u.FullName, "position_id": u.PositionID, "badge": u.Login != "", "username": u.Username,
		})
	})
	return id, err
}

// UserChange — правка пользователя к записи; nil — поле не меняется. Новый вход — новый
// хеш и, для бейджа, новый логин.
type UserChange struct {
	ID           string
	FullName     *string
	PositionID   *string
	IsActive     *bool
	Login        *string
	PasswordHash *string
	// BadgeSecretEnc — номер нового бейджа для печати (ADHOC-65); пишется вместе с Login,
	// nil при новом бейдже стирает прежний номер.
	BadgeSecretEnc []byte
	By             string
}

// UpdateUser правит пользователя. Правка, после которой ни у одного активного пользователя не
// осталось права «пользователи», откатывается с ErrLastAdmin.
func (r *UserAdminRepository) UpdateUser(ctx context.Context, c UserChange) error {
	return r.inTx(ctx, func(q Querier) error {
		var exists bool
		if err := q.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM users WHERE id = $1::uuid)`, c.ID).Scan(&exists); err != nil {
			return fmt.Errorf("пользователь: %w", err)
		}
		if !exists {
			return model.ErrUserMissing
		}
		if c.PositionID != nil {
			if err := checkPositionExists(ctx, q, *c.PositionID); err != nil {
				return err
			}
		}
		if _, err := q.Exec(ctx, `
			UPDATE users SET
			    full_name     = COALESCE($2, full_name),
			    position_id   = COALESCE($3::uuid, position_id),
			    is_active     = COALESCE($4, is_active),
			    login         = COALESCE($5, login),
			    password_hash = COALESCE($6, password_hash),
			    badge_secret_enc = CASE WHEN $5::text IS NULL THEN badge_secret_enc ELSE $7 END
			WHERE id = $1::uuid`, c.ID, c.FullName, c.PositionID, c.IsActive, c.Login, c.PasswordHash,
			c.BadgeSecretEnc); err != nil {
			return userError(err)
		}
		if err := checkAdminsLeft(ctx, q); err != nil {
			return err
		}
		details := map[string]any{}
		if c.FullName != nil {
			details["full_name"] = *c.FullName
		}
		if c.PositionID != nil {
			details["position_id"] = *c.PositionID
		}
		if c.IsActive != nil {
			details["is_active"] = *c.IsActive
		}
		if c.Login != nil {
			details["badge_changed"] = true
		} else if c.PasswordHash != nil {
			details["password_changed"] = true
		}
		return audit(ctx, q, c.By, "user.update", "user", c.ID, details)
	})
}

// IsBadgeUser — входит ли пользователь по бейджу (иначе — по логину и паролю).
func (r *UserAdminRepository) IsBadgeUser(ctx context.Context, id string) (bool, error) {
	var badge bool
	err := r.pool.QueryRow(ctx, `SELECT login IS NOT NULL FROM users WHERE id = $1::uuid`, id).Scan(&badge)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, model.ErrUserMissing
	}
	if err != nil {
		return false, fmt.Errorf("вход пользователя: %w", err)
	}
	return badge, nil
}

func (r *UserAdminRepository) inTx(ctx context.Context, fn func(Querier) error) error {
	return WithinTx(ctx, r.pool, func(q Querier) error {
		if _, err := q.Exec(ctx, `SELECT pg_advisory_xact_lock($1)`, userAdminLockKey); err != nil {
			return fmt.Errorf("блокировка правки пользователей: %w", err)
		}
		return fn(q)
	})
}

// checkPositionEditable — должность есть и не системная.
func checkPositionEditable(ctx context.Context, q Querier, id string) error {
	var system bool
	err := q.QueryRow(ctx, `SELECT is_system FROM positions WHERE id = $1::uuid FOR UPDATE`, id).Scan(&system)
	if errors.Is(err, pgx.ErrNoRows) {
		return model.ErrPositionNotFound
	}
	if err != nil {
		return fmt.Errorf("должность: %w", err)
	}
	if system {
		return model.ErrPositionSystem
	}
	return nil
}

func checkPositionExists(ctx context.Context, q Querier, id string) error {
	var exists bool
	if err := q.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM positions WHERE id = $1::uuid)`, id).Scan(&exists); err != nil {
		return fmt.Errorf("должность: %w", err)
	}
	if !exists {
		return model.ErrPositionNotFound
	}
	return nil
}

// checkAdminsLeft — после правки остался хотя бы один активный пользователь с правом
// «пользователи»: иначе управлять пользователями и должностями стало бы некому.
func checkAdminsLeft(ctx context.Context, q Querier) error {
	var left bool
	if err := q.QueryRow(ctx, `
		SELECT EXISTS (
		    SELECT 1 FROM users u JOIN positions p ON p.id = u.position_id
		    WHERE u.is_active AND (p.is_system OR 'users' = ANY (p.rights)))`).Scan(&left); err != nil {
		return fmt.Errorf("кто управляет пользователями: %w", err)
	}
	if !left {
		return model.ErrLastAdmin
	}
	return nil
}

// audit пишет правку пользователей и должностей в audit_log.
func audit(ctx context.Context, q Querier, by, action, entity, id string, details map[string]any) error {
	raw, err := json.Marshal(details)
	if err != nil {
		return fmt.Errorf("правка для журнала: %w", err)
	}
	if _, err := q.Exec(ctx, `
		INSERT INTO audit_log (user_id, action, entity_type, entity_id, details)
		VALUES (NULLIF($1, '')::uuid, $2, $3, $4, $5::jsonb)`, by, action, entity, id, string(raw)); err != nil {
		return fmt.Errorf("журнал %s: %w", action, err)
	}
	return nil
}

func positionError(err error) error {
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) && pgErr.Code == "23505" {
		return model.ErrPositionNameTaken
	}
	return fmt.Errorf("записать должность: %w", err)
}

func userError(err error) error {
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) && pgErr.Code == "23505" {
		if pgErr.ConstraintName == "users_username_key" {
			return model.ErrUsernameTaken
		}
		return model.ErrBadgeTaken
	}
	return fmt.Errorf("записать пользователя: %w", err)
}
