package service

import (
	"context"
	"net/http"

	"craftwms/internal/model"
)

// problemPhotoRepo — хранилище фото проблем.
type problemPhotoRepo interface {
	Save(ctx context.Context, in model.ProblemPhotoInput) error
	Get(ctx context.Context, problemID, photoID string) (model.ProblemPhoto, error)
}

// ProblemPhotoService — фото к проблемам склада (ADHOC-45): приём снимка с ТСД и отдача.
type ProblemPhotoService struct {
	repo problemPhotoRepo
}

// NewProblemPhotoService создаёт сервис фото проблем.
func NewProblemPhotoService(repo problemPhotoRepo) *ProblemPhotoService {
	return &ProblemPhotoService{repo: repo}
}

// photoTypes — какие снимки принимаем. Тип определяется по содержимому: заголовку клиента
// верить незачем, а мусор под видом картинки в базе не нужен.
var photoTypes = map[string]bool{"image/jpeg": true, "image/png": true, "image/webp": true}

// Save проверяет снимок без базы — идентификаторы, размер, что это картинка — и сохраняет.
func (s *ProblemPhotoService) Save(ctx context.Context, in model.ProblemPhotoInput) error {
	if !isUUID(in.ID) || !isUUID(in.ProblemID) || len(in.Content) == 0 {
		return model.ErrPhotoInvalid
	}
	if len(in.Content) > model.ProblemPhotoMaxBytes {
		return model.ErrPhotoTooLarge
	}
	in.ContentType = http.DetectContentType(in.Content)
	if !photoTypes[in.ContentType] {
		return model.ErrPhotoInvalid
	}
	return s.repo.Save(ctx, in)
}

// Get — снимок проблемы.
func (s *ProblemPhotoService) Get(ctx context.Context, problemID, photoID string) (model.ProblemPhoto, error) {
	if !isUUID(problemID) || !isUUID(photoID) {
		return model.ProblemPhoto{}, model.ErrPhotoNotFound
	}
	return s.repo.Get(ctx, problemID, photoID)
}
