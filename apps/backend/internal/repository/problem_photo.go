package repository

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"craftwms/internal/model"
)

// ProblemPhotoRepository - фото к проблемам склада (ADHOC-45).
type ProblemPhotoRepository struct {
	pool *pgxpool.Pool
}

// NewProblemPhotoRepository создаёт репозиторий фото проблем.
func NewProblemPhotoRepository(pool *pgxpool.Pool) *ProblemPhotoRepository {
	return &ProblemPhotoRepository{pool: pool}
}

// Save сохраняет снимок проблемы - идемпотентно по его идентификатору.
//
// Как: проблема блокируется на время записи - без этого две загрузки одновременно увидели бы
// по два фото и обе легли бы четвёртым и пятым. Повтор того же снимка (очередь ТСД не узнала
// ответ) - успех без второй записи, даже если проблему за это время решили: снимок уже есть.
// Новый снимок - только к открытой проблеме и не больше [model.ProblemPhotoMax].
func (r *ProblemPhotoRepository) Save(ctx context.Context, in model.ProblemPhotoInput) error {
	return WithinTx(ctx, r.pool, func(q Querier) error {
		var status string
		err := q.QueryRow(ctx, `
			SELECT status FROM warehouse_problems WHERE id = $1::uuid FOR UPDATE`, in.ProblemID).Scan(&status)
		if errors.Is(err, pgx.ErrNoRows) {
			return model.ErrPhotoProblemNotFound
		}
		if err != nil {
			return fmt.Errorf("проблема фото: %w", err)
		}

		var owner string
		err = q.QueryRow(ctx, `SELECT problem_id::text FROM problem_photos WHERE id = $1::uuid`, in.ID).Scan(&owner)
		switch {
		case err == nil && owner == in.ProblemID:
			return nil
		case err == nil:
			return model.ErrPhotoIDTaken
		case !errors.Is(err, pgx.ErrNoRows):
			return fmt.Errorf("фото по id: %w", err)
		}

		if status != model.ProblemStatusOpen {
			return model.ErrPhotoProblemResolved
		}
		var count int
		if err := q.QueryRow(ctx, `
			SELECT count(*) FROM problem_photos WHERE problem_id = $1::uuid`, in.ProblemID).Scan(&count); err != nil {
			return fmt.Errorf("число фото проблемы: %w", err)
		}
		if count >= model.ProblemPhotoMax {
			return model.ErrPhotoLimit
		}
		if _, err := q.Exec(ctx, `
			INSERT INTO problem_photos (id, problem_id, content, content_type, size_bytes, created_by)
			VALUES ($1::uuid, $2::uuid, $3, $4, $5, $6::uuid)`,
			in.ID, in.ProblemID, in.Content, in.ContentType, len(in.Content), in.CreatedBy); err != nil {
			return fmt.Errorf("записать фото проблемы: %w", err)
		}
		return nil
	})
}

// Get - снимок проблемы целиком. ErrPhotoNotFound - нет такого фото у этой проблемы.
func (r *ProblemPhotoRepository) Get(ctx context.Context, problemID, photoID string) (model.ProblemPhoto, error) {
	var p model.ProblemPhoto
	err := r.pool.QueryRow(ctx, `
		SELECT id::text, problem_id::text, content_type, content, created_at
		FROM problem_photos WHERE id = $1::uuid AND problem_id = $2::uuid`, photoID, problemID).
		Scan(&p.ID, &p.ProblemID, &p.ContentType, &p.Content, &p.CreatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return p, model.ErrPhotoNotFound
	}
	if err != nil {
		return p, fmt.Errorf("фото проблемы: %w", err)
	}
	return p, nil
}
