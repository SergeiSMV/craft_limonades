package service

import (
	"context"
	"fmt"

	"craftwms/internal/model"
	"craftwms/internal/report"
)

// stockEntryReportRepo — зависимость сервиса отчёта от хранилища.
type stockEntryReportRepo interface {
	Report(ctx context.Context, sessionID string) (model.StockEntryReport, error)
	ListClosedDocuments(ctx context.Context) ([]model.StockEntryDocument, error)
}

// StockEntryReportService — генерация Excel-отчёта «ввод остатков» по закрытой сессии (P-FS-08).
type StockEntryReportService struct {
	repo stockEntryReportRepo
}

// NewStockEntryReportService собирает сервис отчёта.
func NewStockEntryReportService(repo stockEntryReportRepo) *StockEntryReportService {
	return &StockEntryReportService{repo: repo}
}

// Report возвращает байты .xlsx и имя файла для сессии. Доменные ошибки репозитория
// (ErrSessionNotFound/ErrSessionNotClosed) проходят как есть — хендлер маппит их в 404/409.
func (s *StockEntryReportService) Report(ctx context.Context, sessionID string) ([]byte, string, error) {
	rep, err := s.repo.Report(ctx, sessionID)
	if err != nil {
		return nil, "", err
	}
	data, err := report.BuildStockEntryXLSX(rep)
	if err != nil {
		return nil, "", err
	}
	filename := fmt.Sprintf("vvod-ostatkov-%s-%s.xlsx", rep.WarehouseCode, rep.CreatedAt.Format("20060102"))
	return data, filename, nil
}

// ListDocuments — закрытые сессии как документы «ввод остатков» для портала «Инвентаризация».
func (s *StockEntryReportService) ListDocuments(ctx context.Context) ([]model.StockEntryDocument, error) {
	return s.repo.ListClosedDocuments(ctx)
}
