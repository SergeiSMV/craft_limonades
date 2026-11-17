package service

import (
	"context"
	"log/slog"

	"craftwms/internal/model"
	"craftwms/internal/report"
)

// documentRepo - зависимость сервиса от хранилища документов.
type documentRepo interface {
	List(ctx context.Context, kind string) ([]model.DocumentListItem, error)
	ByID(ctx context.Context, id string) (model.ReportDocument, error)
	KindByID(ctx context.Context, id string) (string, error)
	MarkDownloaded(ctx context.Context, id string) error
	MarkDone(ctx context.Context, id string) error
	LogEvent(ctx context.Context, documentID, event, userID, details string) error
	Events(ctx context.Context, documentID string) ([]model.DocumentEvent, error)
}

// DocumentService - рабочий список документов оператора (P3-02): что опубликовано, что скачано,
// что занесено в 1С. Файл здесь же и собирается - из снимка, а не из живых справочников.
type DocumentService struct {
	repo documentRepo
}

// NewDocumentService собирает сервис документов.
func NewDocumentService(repo documentRepo) *DocumentService {
	return &DocumentService{repo: repo}
}

// List отдаёт список документов для портала; kind пуст - все формы, иначе одна.
func (s *DocumentService) List(ctx context.Context, kind string) ([]model.DocumentListItem, error) {
	return s.repo.List(ctx, kind)
}

// Kind - вид документа: право на действие с ним зависит от вида (ADHOC-50).
func (s *DocumentService) Kind(ctx context.Context, id string) (string, error) {
	return s.repo.KindByID(ctx, id)
}

// File собирает .xlsx документа и отмечает скачивание. Возвращает байты и имя файла.
//
// Сборка на лету, а не готовый файл из хранилища: снимок уже неизменяем (P3-01), поэтому
// результат детерминирован, а правка шаблона задним числом применяется и к старым документам.
//
// userID передаётся параметром, а не берётся из контекста: журналу нужен явный автор действия,
// и зависимость, которую видно в сигнатуре, не забудут прокинуть.
func (s *DocumentService) File(ctx context.Context, id, userID string) ([]byte, string, error) {
	doc, err := s.repo.ByID(ctx, id)
	if err != nil {
		return nil, "", err
	}

	data, err := report.BuildDocumentXLSX(doc)
	if err != nil {
		// Неудачная сборка - тоже судьба документа: оператор видит ошибку, и без записи
		// разбирать было бы нечего. Ошибку журнала не подменяем исходной - она важнее.
		if logErr := s.repo.LogEvent(ctx, id, model.DocEventGenerationFailed, userID, err.Error()); logErr != nil {
			slog.Error("не записал событие неудачной сборки", "document", id, "error", logErr)
		}
		return nil, "", err
	}

	// Отметку ставим ПОСЛЕ успешной сборки: файл, который не собрался, оператор не получил,
	// и помечать его скачанным было бы неправдой.
	if err := s.repo.MarkDownloaded(ctx, id); err != nil {
		return nil, "", err
	}
	// Событие пишется на КАЖДОЕ скачивание, в отличие от статуса: спор с 1С - всегда про историю,
	// а не про последнее состояние.
	if err := s.repo.LogEvent(ctx, id, model.DocEventDownloaded, userID, ""); err != nil {
		return nil, "", err
	}
	return data, report.DocumentFilename(doc), nil
}

// MarkDone отмечает документ занесённым в 1С.
func (s *DocumentService) MarkDone(ctx context.Context, id, userID string) error {
	if id == "" {
		return model.ErrEmptyDocumentID
	}
	if err := s.repo.MarkDone(ctx, id); err != nil {
		return err
	}
	return s.repo.LogEvent(ctx, id, model.DocEventDone, userID, "")
}

// Events отдаёт историю документа. Пустая история у существующего документа невозможна:
// событие «сформирован» рождается вместе с ним, поэтому пустой ответ означает, что документа нет.
func (s *DocumentService) Events(ctx context.Context, id string) ([]model.DocumentEvent, error) {
	if id == "" {
		return nil, model.ErrEmptyDocumentID
	}
	if _, err := s.repo.ByID(ctx, id); err != nil {
		return nil, err
	}
	return s.repo.Events(ctx, id)
}
