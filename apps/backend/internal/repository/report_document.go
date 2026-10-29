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
// Возвращает id созданного документа или пустую строку, если документ по этой операции уже был:
// пустой id — признак повтора, по которому вызывающий понимает, что заводить событие журнала
// «сформирован» второй раз не нужно.
func saveDocument(ctx context.Context, q Querier, doc model.ReportDocument) (string, error) {
	raw, err := json.Marshal(doc.Snapshot)
	if err != nil {
		return "", fmt.Errorf("сериализовать снимок документа: %w", err)
	}
	var id string
	err = q.QueryRow(ctx, `
		INSERT INTO report_documents (kind, source_type, source_id, snapshot)
		VALUES ($1, $2, $3::uuid, $4)
		ON CONFLICT (source_type, source_id) DO NOTHING
		RETURNING id::text`,
		doc.Kind, doc.SourceType, doc.SourceID, raw).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", nil
	}
	if err != nil {
		return "", fmt.Errorf("сохранить документ отчёта: %w", err)
	}
	return id, nil
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
//
// kind пуст — все формы; иначе только одна: у каждой формы в портале своя вкладка
// («Инвентаризация», «Приход», «Движение»), и смешанный список заставил бы оператора искать свои документы
// среди чужих.
func (r *ReportDocumentRepository) List(ctx context.Context, kind string) ([]model.DocumentListItem, error) {
	rows, err := r.pool.Query(ctx, `
		SELECT id::text, kind,
		       snapshot->>'warehouse_code', snapshot->>'warehouse_name',
		       COALESCE(snapshot->>'supplier', ''),
		       COALESCE(snapshot->>'doc_number', ''), COALESCE(snapshot->>'doc_date', ''),
		       COALESCE(snapshot->>'operation', ''), COALESCE((snapshot->>'task_number')::bigint, 0),
		       COALESCE((snapshot->>'problem_number')::bigint, 0),
		       COALESCE(snapshot->>'executor', ''), COALESCE((snapshot->>'stocktake_number')::bigint, 0),
		       created_at,
		       jsonb_array_length(COALESCE(snapshot->'rows', '[]'::jsonb)),
		       status, downloaded_at, done_at
		FROM report_documents
		WHERE ($1 = '' OR kind = $1)
		ORDER BY (status = 'done'), created_at DESC`, kind)
	if err != nil {
		return nil, fmt.Errorf("список документов: %w", err)
	}
	defer rows.Close()

	out := make([]model.DocumentListItem, 0)
	for rows.Next() {
		var d model.DocumentListItem
		if err := rows.Scan(&d.ID, &d.Kind, &d.WarehouseCode, &d.WarehouseName, &d.Supplier,
			&d.DocNumber, &d.DocDate, &d.Operation, &d.TaskNumber, &d.ProblemNumber, &d.Executor, &d.StocktakeNumber, &d.CreatedAt, &d.LinesCount, &d.Status, &d.DownloadedAt, &d.DoneAt); err != nil {
			return nil, fmt.Errorf("разбор строки списка документов: %w", err)
		}
		out = append(out, d)
	}
	return out, rows.Err()
}

// ByID читает документ вместе со снимком — для сборки файла.
// KindByID — вид документа (ADHOC-50): по нему проверяется право на действие с ним.
// Нет документа (или id не uuid) — ErrDocumentNotFound.
func (r *ReportDocumentRepository) KindByID(ctx context.Context, id string) (string, error) {
	var kind string
	err := r.pool.QueryRow(ctx, `SELECT kind FROM report_documents
		WHERE id::text = $1`, id).Scan(&kind)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", ErrDocumentNotFound
	}
	if err != nil {
		return "", fmt.Errorf("вид документа: %w", err)
	}
	return kind, nil
}

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

// logEvent дописывает запись в журнал документа (P3-03).
//
// Принимает Querier, а не пул: событие «сформирован» обязано лечь в ту же транзакцию, что и сам
// документ, — иначе документ и его история могли бы разойтись при сбое между ними.
// userID пустой → NULL: событие системное, и выдумывать автора нельзя.
func logEvent(ctx context.Context, q Querier, documentID, event, userID, details string) error {
	var user any
	if userID != "" {
		user = userID
	}
	payload := map[string]string{}
	if details != "" {
		payload["message"] = details
	}
	raw, err := json.Marshal(payload)
	if err != nil {
		return fmt.Errorf("сериализовать детали события: %w", err)
	}
	if _, err := q.Exec(ctx, `
		INSERT INTO report_document_events (document_id, event, user_id, details)
		VALUES ($1::uuid, $2, $3::uuid, $4)`, documentID, event, user, raw); err != nil {
		return fmt.Errorf("записать событие журнала: %w", err)
	}
	return nil
}

// LogEvent дописывает событие журнала вне транзакции — для действий из портала.
func (r *ReportDocumentRepository) LogEvent(ctx context.Context, documentID, event, userID, details string) error {
	return logEvent(ctx, r.pool, documentID, event, userID, details)
}

// Events возвращает историю документа по времени. ФИО подтягивается из users: журнал хранит
// ссылку, а не копию имени, — переименование сотрудника не должно рождать двух разных людей.
func (r *ReportDocumentRepository) Events(ctx context.Context, documentID string) ([]model.DocumentEvent, error) {
	rows, err := r.pool.Query(ctx, `
		SELECT e.event, e.user_id::text, COALESCE(u.full_name, ''), COALESCE(e.details->>'message', ''), e.created_at
		FROM report_document_events e
		LEFT JOIN users u ON u.id = e.user_id
		WHERE e.document_id = $1::uuid
		ORDER BY e.created_at, e.id`, documentID)
	if err != nil {
		return nil, fmt.Errorf("журнал документа: %w", err)
	}
	defer rows.Close()

	out := make([]model.DocumentEvent, 0)
	for rows.Next() {
		var ev model.DocumentEvent
		if err := rows.Scan(&ev.Event, &ev.UserID, &ev.UserName, &ev.Details, &ev.CreatedAt); err != nil {
			return nil, fmt.Errorf("разбор события журнала: %w", err)
		}
		out = append(out, ev)
	}
	return out, rows.Err()
}
