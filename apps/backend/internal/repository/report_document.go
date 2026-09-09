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

// List возвращает документы для портала: сначала необработанные, свежие сверху.
//
// Порядок «сначала работа, потом сделанное» — суть трекаемого списка: выполненные документы
// не исчезают (по ним сверяются), но и не заслоняют то, чем ещё предстоит заняться.
// Число строк берётся из СНИМКА, а не из таблицы-источника: документ описывает операцию такой,
// какой она была завершена.
func (r *ReportDocumentRepository) List(ctx context.Context) ([]model.DocumentListItem, error) {
	rows, err := r.pool.Query(ctx, `
		SELECT id::text, kind,
		       snapshot->>'warehouse_code', snapshot->>'warehouse_name',
		       created_at,
		       jsonb_array_length(COALESCE(snapshot->'rows', '[]'::jsonb)),
		       status, downloaded_at, done_at
		FROM report_documents
		ORDER BY (status = 'done'), created_at DESC`)
	if err != nil {
		return nil, fmt.Errorf("список документов: %w", err)
	}
	defer rows.Close()

	out := make([]model.DocumentListItem, 0)
	for rows.Next() {
		var d model.DocumentListItem
		if err := rows.Scan(&d.ID, &d.Kind, &d.WarehouseCode, &d.WarehouseName,
			&d.CreatedAt, &d.LinesCount, &d.Status, &d.DownloadedAt, &d.DoneAt); err != nil {
			return nil, fmt.Errorf("разбор строки списка документов: %w", err)
		}
		out = append(out, d)
	}
	return out, rows.Err()
}

// ByID читает документ вместе со снимком — для сборки файла.
func (r *ReportDocumentRepository) ByID(ctx context.Context, id string) (model.ReportDocument, error) {
	var doc model.ReportDocument
	var raw []byte
	err := r.pool.QueryRow(ctx, `
		SELECT id::text, kind, source_type, source_id::text, snapshot, created_at
		FROM report_documents WHERE id = $1::uuid`, id).
		Scan(&doc.ID, &doc.Kind, &doc.SourceType, &doc.SourceID, &raw, &doc.CreatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return model.ReportDocument{}, ErrDocumentNotFound
	}
	if err != nil {
		return model.ReportDocument{}, fmt.Errorf("прочитать документ: %w", err)
	}
	if err := json.Unmarshal(raw, &doc.Snapshot); err != nil {
		return model.ReportDocument{}, fmt.Errorf("разобрать снимок документа: %w", err)
	}
	return doc, nil
}

// MarkDownloaded отмечает первое скачивание.
//
// Статус двигается ТОЛЬКО из 'new': скачивание уже выполненного документа не возвращает его
// в работу — оператор мог открыть файл для сверки, и откатывать отметку «занесено в 1С» по
// такому поводу нельзя. Время первого скачивания тоже не переписывается (COALESCE).
func (r *ReportDocumentRepository) MarkDownloaded(ctx context.Context, id string) error {
	tag, err := r.pool.Exec(ctx, `
		UPDATE report_documents
		SET status        = CASE WHEN status = 'new' THEN 'downloaded' ELSE status END,
		    downloaded_at = COALESCE(downloaded_at, now())
		WHERE id = $1::uuid`, id)
	if err != nil {
		return fmt.Errorf("отметить скачивание: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return ErrDocumentNotFound
	}
	return nil
}

// MarkDone отмечает документ занесённым в 1С. Идемпотентно: повтор не двигает время отметки,
// а промежуточный статус не требуется — данные могли попасть в 1С и без скачивания файла.
func (r *ReportDocumentRepository) MarkDone(ctx context.Context, id string) error {
	tag, err := r.pool.Exec(ctx, `
		UPDATE report_documents
		SET status = 'done', done_at = COALESCE(done_at, now())
		WHERE id = $1::uuid`, id)
	if err != nil {
		return fmt.Errorf("отметить выполнение: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return ErrDocumentNotFound
	}
	return nil
}
