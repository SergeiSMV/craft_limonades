package repository

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"craftwms/internal/model"
)

// ErrDocumentNotFound — документа по такой операции нет: она не завершена либо завершена до
// появления снимков и не попала в бэкофилл.
var ErrDocumentNotFound = errors.New("report document not found")

// ReportDocumentRepository — доступ к документам отчётов (P3-01).
type ReportDocumentRepository struct {
	pool *pgxpool.Pool
}

// NewReportDocumentRepository собирает репозиторий документов.
func NewReportDocumentRepository(pool *pgxpool.Pool) *ReportDocumentRepository {
	return &ReportDocumentRepository{pool: pool}
}

// BySource возвращает снимок документа по операции-источнику.
func (r *ReportDocumentRepository) BySource(ctx context.Context, sourceType, sourceID string) (model.ReportDocument, error) {
	return documentBySource(ctx, r.pool, sourceType, sourceID)
}

// saveDocument пишет снимок документа. Принимает Querier, а не пул: снимок должен лечь в ТУ ЖЕ
// транзакцию, что и закрытие операции, иначе между ними появляется окно, в котором операция
// завершена, а документа нет.
//
// Повтор безвреден: при конфликте по (source_type, source_id) сохраняется ПЕРВЫЙ снимок.
// Так и нужно — повторный финал из очереди устройства (P2-05) не должен переписывать документ
// содержимым, собранным позже по изменившимся справочникам.
func saveDocument(ctx context.Context, q Querier, doc model.ReportDocument) error {
	raw, err := json.Marshal(doc.Snapshot)
	if err != nil {
		return fmt.Errorf("сериализовать снимок документа: %w", err)
	}
	if _, err := q.Exec(ctx, `
		INSERT INTO report_documents (kind, source_type, source_id, snapshot)
		VALUES ($1, $2, $3::uuid, $4)
		ON CONFLICT (source_type, source_id) DO NOTHING`,
		doc.Kind, doc.SourceType, doc.SourceID, raw); err != nil {
		return fmt.Errorf("сохранить документ отчёта: %w", err)
	}
	return nil
}

// documentBySource — чтение снимка на Querier (годится и для пула, и для транзакции).
func documentBySource(ctx context.Context, q Querier, sourceType, sourceID string) (model.ReportDocument, error) {
	var doc model.ReportDocument
	var raw []byte
	err := q.QueryRow(ctx, `
		SELECT id::text, kind, source_type, source_id::text, snapshot, created_at
		FROM report_documents
		WHERE source_type = $1 AND source_id = $2::uuid`, sourceType, sourceID).
		Scan(&doc.ID, &doc.Kind, &doc.SourceType, &doc.SourceID, &raw, &doc.CreatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return model.ReportDocument{}, ErrDocumentNotFound
	}
	if err != nil {
		return model.ReportDocument{}, fmt.Errorf("прочитать документ отчёта: %w", err)
	}
	if err := json.Unmarshal(raw, &doc.Snapshot); err != nil {
		return model.ReportDocument{}, fmt.Errorf("разобрать снимок документа: %w", err)
	}
	return doc, nil
}
