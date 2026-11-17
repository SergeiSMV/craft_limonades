package repository

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"craftwms/internal/model"
)

// BadgeRepository - сотрудники с бейджами для печати на ТСД (ADHOC-65).
type BadgeRepository struct {
	pool *pgxpool.Pool
}

// NewBadgeRepository создаёт репозиторий бейджей.
func NewBadgeRepository(pool *pgxpool.Pool) *BadgeRepository {
	return &BadgeRepository{pool: pool}
}

const badgeHolderSelect = `
	SELECT u.id::text, u.full_name, p.name, p.is_system, u.login, u.badge_secret_enc
	FROM users u JOIN positions p ON p.id = u.position_id
	WHERE u.is_active AND u.login IS NOT NULL`

// Holders - активные сотрудники, входящие по бейджу, по ФИО.
func (r *BadgeRepository) Holders(ctx context.Context) ([]model.BadgeHolder, error) {
	rows, err := r.pool.Query(ctx, badgeHolderSelect+` ORDER BY u.full_name, u.id`)
	if err != nil {
		return nil, fmt.Errorf("сотрудники с бейджами: %w", err)
	}
	defer rows.Close()
	var out []model.BadgeHolder
	for rows.Next() {
		var h model.BadgeHolder
		if err := rows.Scan(&h.ID, &h.FullName, &h.PositionName, &h.IsAdmin, &h.Login, &h.Sealed); err != nil {
			return nil, fmt.Errorf("сотрудник с бейджем: %w", err)
		}
		out = append(out, h)
	}
	return out, rows.Err()
}

// Holder - сотрудник с бейджем по id; нет, заблокирован или входит по паролю - ErrUserMissing.
func (r *BadgeRepository) Holder(ctx context.Context, id string) (model.BadgeHolder, error) {
	var h model.BadgeHolder
	err := r.pool.QueryRow(ctx, badgeHolderSelect+` AND u.id = $1::uuid`, id).
		Scan(&h.ID, &h.FullName, &h.PositionName, &h.IsAdmin, &h.Login, &h.Sealed)
	if errors.Is(err, pgx.ErrNoRows) {
		return model.BadgeHolder{}, model.ErrUserMissing
	}
	if err != nil {
		return model.BadgeHolder{}, fmt.Errorf("сотрудник с бейджем: %w", err)
	}
	return h, nil
}

// LogPrint пишет в audit_log, кто чей бейдж выдал на печать.
func (r *BadgeRepository) LogPrint(ctx context.Context, by, id string) error {
	return audit(ctx, r.pool, by, "badge.print", "user", id, map[string]any{})
}
