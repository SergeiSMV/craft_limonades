package model

import (
	"errors"
	"time"
)

// Фото к проблеме склада (ADHOC-45): снимает ТСД, хранятся в базе.

// ProblemPhotoMax — сколько фото может быть у одной проблемы.
const ProblemPhotoMax = 3

// ProblemPhotoMaxBytes — предел размера снимка. ТСД сжимает до ~1600 px JPEG (200–400 КБ);
// больше — ошибка клиента, а не снимок склада.
const ProblemPhotoMaxBytes = 1 << 20

// Ошибки фото проблемы. Все — отказ по существу: повтор той же загрузки их не исправит.
var (
	// ErrPhotoProblemNotFound — проблемы нет (или ещё нет: её операция не дошла до сервера).
	ErrPhotoProblemNotFound = errors.New("problem of the photo not found")
	// ErrPhotoNotFound — фото нет.
	ErrPhotoNotFound = errors.New("problem photo not found")
	// ErrPhotoProblemResolved — по проблеме уже принято решение: фото к ней не добавляют.
	ErrPhotoProblemResolved = errors.New("problem is resolved, photos are closed")
	// ErrPhotoLimit — у проблемы уже ProblemPhotoMax фото.
	ErrPhotoLimit = errors.New("problem already has the maximum number of photos")
	// ErrPhotoIDTaken — идентификатор фото уже занят снимком другой проблемы.
	ErrPhotoIDTaken = errors.New("photo id belongs to another problem")
	// ErrPhotoInvalid — не снимок: пусто, не JPEG/PNG/WebP или идентификаторы не UUID.
	ErrPhotoInvalid = errors.New("invalid problem photo")
	// ErrPhotoTooLarge — снимок больше ProblemPhotoMaxBytes.
	ErrPhotoTooLarge = errors.New("problem photo is too large")
)

// ProblemPhotoInput — снимок, присланный ТСД.
type ProblemPhotoInput struct {
	ID          string // выдаёт устройство
	ProblemID   string
	ContentType string // определён по содержимому, не по заголовку клиента
	Content     []byte
	CreatedBy   string
}

// ProblemPhoto — снимок для отдачи.
type ProblemPhoto struct {
	ID          string
	ProblemID   string
	ContentType string
	Content     []byte
	CreatedAt   time.Time
}
