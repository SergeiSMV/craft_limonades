package repository

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"craftwms/internal/model"
)

// problemReasonsLockKey - рекомендательная блокировка правки справочника причин: две правки
// из портала не перепишут список вариантов причины вперемешку.
const problemReasonsLockKey = 1030

// ProblemReasonRepository - справочник причин проблем и вариантов решения (ADHOC-55): чтение
// для ТСД и портала, ведение - из портала. Каждая правка пишется в audit_log.
type ProblemReasonRepository struct {
	pool *pgxpool.Pool
}

// NewProblemReasonRepository создаёт репозиторий справочника причин.
func NewProblemReasonRepository(pool *pgxpool.Pool) *ProblemReasonRepository {
	return &ProblemReasonRepository{pool: pool}
}

// Reasons - все причины, и неактивные, в порядке заведения; у каждой - коды вариантов в порядке
// справочника вариантов.
func (r *ProblemReasonRepository) Reasons(ctx context.Context) ([]model.ProblemReason, error) {
	rows, err := r.pool.Query(ctx, `
		SELECT pr.code, pr.name, pr.is_system, pr.manual, pr.comment_required, pr.is_active,
		       ARRAY(SELECT x.id::text FROM problem_reason_resolutions l
		             JOIN problem_resolutions x ON x.id = l.resolution_id
		             WHERE l.reason = pr.code ORDER BY x.ord)
		FROM problem_reasons pr
		ORDER BY pr.ord`)
	if err != nil {
		return nil, fmt.Errorf("причины проблем: %w", err)
	}
	return pgx.CollectRows(rows, func(row pgx.CollectableRow) (model.ProblemReason, error) {
		var p model.ProblemReason
		err := row.Scan(&p.Code, &p.Name, &p.IsSystem, &p.Manual, &p.CommentRequired, &p.IsActive, &p.Resolutions)
		return p, err
	})
}

// Resolutions - все варианты решения, и неактивные, в порядке заведения.
func (r *ProblemReasonRepository) Resolutions(ctx context.Context) ([]model.ProblemResolution, error) {
	rows, err := r.pool.Query(ctx, `
		SELECT id::text, name, action, is_active FROM problem_resolutions ORDER BY ord`)
	if err != nil {
		return nil, fmt.Errorf("варианты решения: %w", err)
	}
	return pgx.CollectRows(rows, func(row pgx.CollectableRow) (model.ProblemResolution, error) {
		var x model.ProblemResolution
		err := row.Scan(&x.ID, &x.Name, &x.Action, &x.IsActive)
		return x, err
	})
}

// resolutionByID - один вариант решения; нет такого - ErrResolutionNotFound. Общий у
// справочника и решения по проблеме.
func resolutionByID(ctx context.Context, q Querier, id string) (model.ProblemResolution, error) {
	var x model.ProblemResolution
	err := q.QueryRow(ctx, `
		SELECT id::text, name, action, is_active FROM problem_resolutions WHERE id = $1::uuid`, id).
		Scan(&x.ID, &x.Name, &x.Action, &x.IsActive)
	if errors.Is(err, pgx.ErrNoRows) {
		return x, model.ErrResolutionNotFound
	}
	if err != nil {
		return x, fmt.Errorf("вариант решения: %w", err)
	}
	return x, nil
}

// SaveReason заводит причину (пустой код) или правит её; возвращает код.
//
// Как: одной транзакцией под блокировкой справочника - запись причины и, если список передан,
// замена её вариантов целиком. Системную причину выключить нельзя; правило «пересорт только
// у пересорта» держит триггер базы, его отказ переводится в ErrResolutionRegradeMismatch.
func (r *ProblemReasonRepository) SaveReason(ctx context.Context, in model.ProblemReasonInput) (string, error) {
	code := in.Code
	err := r.inTx(ctx, func(q Querier) error {
		if code == "" {
			if err := q.QueryRow(ctx, `
				INSERT INTO problem_reasons (name, comment_required) VALUES ($1, COALESCE($2, false))
				RETURNING code`, in.Name, in.CommentRequired).Scan(&code); err != nil {
				return reasonError(err)
			}
		} else {
			var system bool
			err := q.QueryRow(ctx, `SELECT is_system FROM problem_reasons WHERE code = $1 FOR UPDATE`, code).Scan(&system)
			if errors.Is(err, pgx.ErrNoRows) {
				return model.ErrProblemReasonNotFound
			}
			if err != nil {
				return fmt.Errorf("причина: %w", err)
			}
			if system && in.IsActive != nil && !*in.IsActive {
				return model.ErrProblemReasonSystem
			}
			if _, err := q.Exec(ctx, `
				UPDATE problem_reasons
				SET name = COALESCE($2, name), comment_required = COALESCE($3, comment_required),
				    is_active = COALESCE($4, is_active)
				WHERE code = $1`, code, in.Name, in.CommentRequired, in.IsActive); err != nil {
				return reasonError(err)
			}
		}
		if in.Resolutions != nil {
			if _, err := q.Exec(ctx, `DELETE FROM problem_reason_resolutions WHERE reason = $1`, code); err != nil {
				return fmt.Errorf("варианты причины: %w", err)
			}
			for _, id := range *in.Resolutions {
				if _, err := q.Exec(ctx, `
					INSERT INTO problem_reason_resolutions (reason, resolution_id) VALUES ($1, $2::uuid)`,
					code, id); err != nil {
					return reasonError(err)
				}
			}
		}
		action := "problem_reason.update"
		if in.Code == "" {
			action = "problem_reason.create"
		}
		return audit(ctx, q, in.By, action, "problem_reason", code, map[string]any{
			"name": in.Name, "comment_required": in.CommentRequired, "is_active": in.IsActive,
			"resolutions": in.Resolutions,
		})
	})
	return code, err
}

// SaveResolution заводит вариант решения (пустой id) или правит его; возвращает id. Действие
// задаётся только при заведении: им уже проведены решения старых проблем.
func (r *ProblemReasonRepository) SaveResolution(ctx context.Context, in model.ProblemResolutionInput) (string, error) {
	id := in.ID
	err := r.inTx(ctx, func(q Querier) error {
		if id == "" {
			if err := q.QueryRow(ctx, `
				INSERT INTO problem_resolutions (name, action) VALUES ($1, $2) RETURNING id::text`,
				in.Name, in.Action).Scan(&id); err != nil {
				return resolutionError(err)
			}
		} else {
			tag, err := q.Exec(ctx, `
				UPDATE problem_resolutions
				SET name = COALESCE($2, name), is_active = COALESCE($3, is_active)
				WHERE id = $1::uuid`, id, in.Name, in.IsActive)
			if err != nil {
				return resolutionError(err)
			}
			if tag.RowsAffected() == 0 {
				return model.ErrResolutionNotFound
			}
		}
		action := "problem_resolution.update"
		if in.ID == "" {
			action = "problem_resolution.create"
		}
		return audit(ctx, q, in.By, action, "problem_resolution", id, map[string]any{
			"name": in.Name, "action": in.Action, "is_active": in.IsActive,
		})
	})
	return id, err
}

func (r *ProblemReasonRepository) inTx(ctx context.Context, fn func(Querier) error) error {
	return WithinTx(ctx, r.pool, func(q Querier) error {
		if _, err := q.Exec(ctx, `SELECT pg_advisory_xact_lock($1)`, problemReasonsLockKey); err != nil {
			return fmt.Errorf("блокировка справочника причин: %w", err)
		}
		return fn(q)
	})
}

// reasonError переводит отказы базы при записи причины в ошибки для портала.
func reasonError(err error) error {
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) {
		switch pgErr.Code {
		case "23505":
			return model.ErrProblemReasonNameTaken
		case "23503":
			return model.ErrResolutionNotFound
		case "23514":
			if pgErr.ConstraintName == "" {
				// Отказ триггера «пересорт только у пересорта» - у RAISE нет имени ограничения.
				return model.ErrResolutionRegradeMismatch
			}
			return model.ErrInvalidProblemReason
		}
	}
	return fmt.Errorf("записать причину: %w", err)
}

// resolutionError переводит отказы базы при записи варианта в ошибки для портала.
func resolutionError(err error) error {
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) {
		switch pgErr.Code {
		case "23505":
			return model.ErrResolutionNameTaken
		case "23514":
			return model.ErrInvalidResolution
		}
	}
	return fmt.Errorf("записать вариант решения: %w", err)
}
