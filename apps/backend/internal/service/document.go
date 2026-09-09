package service

import (
	"context"
	"errors"

	"craftwms/internal/model"
	"craftwms/internal/report"
)

// ErrEmptyDocumentID — обращение к документу без идентификатора.
var ErrEmptyDocumentID = errors.New("document id is required")

// documentRepo — зависимость сервиса от хранилища документов.
type documentRepo interface {
	List(ctx context.Context) ([]model.DocumentListItem, error)
	ByID(ctx context.Context, id string) (model.ReportDocument, error)
	MarkDownloaded(ctx context.Context, id string) error
	MarkDone(ctx context.Context, id string) error
}

// DocumentService — рабочий список документов оператора (P3-02): что опубликовано, что скачано,
// что занесено в 1С. Файл здесь же и собирается — из снимка, а не из живых справочников.
type DocumentService struct {
	repo documentRepo
}

// NewDocumentService собирает сервис документов.
func NewDocumentService(repo documentRepo) *DocumentService {
	return &DocumentService{repo: repo}
}

// List отдаёт список документов для портала.
func (s *DocumentService) List(ctx context.Context) ([]model.DocumentListItem, error) {
	return s.repo.List(ctx)
}

// File собирает .xlsx документа и отмечает скачивание. Возвращает байты и имя файла.
//
// Сборка на лету, а не готовый файл из хранилища: снимок уже неизменяем (P3-01), поэтому
// результат детерминирован, а правка шаблона задним числом применяется и к старым документам.
func (s *DocumentService) File(ctx context.Context, id string) ([]byte, string, error) {
	doc, err := s.repo.ByID(ctx, id)
	if err != nil {
		return nil, "", err
	}

	data, err := report.BuildDocumentXLSX(doc)
	if err != nil {
		return nil, "", err
	}

	// Отметку ставим ПОСЛЕ успешной сборки: файл, который не собрался, оператор не получил,
	// и помечать его скачанным было бы неправдой.
	if err := s.repo.MarkDownloaded(ctx, id); err != nil {
		return nil, "", err
	}
	return data, report.DocumentFilename(doc), nil
}

// MarkDone отмечает документ занесённым в 1С.
func (s *DocumentService) MarkDone(ctx context.Context, id string) error {
	if id == "" {
		return ErrEmptyDocumentID
	}
	return s.repo.MarkDone(ctx, id)
}
