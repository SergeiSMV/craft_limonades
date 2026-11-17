package model

import "errors"

// ErrNotFound - сущность по id не найдена (точечное чтение). Общий сигнал хранилища: handler
// отвечает на него 404, не зная, какой репозиторий его вернул (ADHOC-71, долг 38).
var ErrNotFound = errors.New("not found")
