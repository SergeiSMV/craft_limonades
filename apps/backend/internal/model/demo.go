package model

import (
	"errors"
	"time"
)

// Демо-режим (ADHOC-67): тот же сервер на отдельной базе с выдуманными данными — для показов
// и модерации в RuStore. Вход без пароля под демо-пользователем, сброс ночью и кнопкой.
const (
	// DemoUserLogin — логин демо-пользователя (8 цифр, как у бейджа). Должность «Администратор».
	DemoUserLogin = "99999999"
	// DemoUserName — ФИО демо-пользователя в шапке ТСД и портала.
	DemoUserName = "Демо-администратор"
	// DemoDatabaseSuffix — окончание имени демо-базы. Другая база демо-режим не включает.
	DemoDatabaseSuffix = "_demo"
	// DemoWarehouseName — название склада демо-данных. Код — боевой по умолчанию (SHB): его ждут
	// загрузка реестра из портала и ТСД.
	DemoWarehouseName = "Демо-склад"
	// DemoResetCooldown — как часто можно сбрасывать демо кнопкой: сброс стирает сеансы всех,
	// кто сейчас в демо, и частые нажатия мешали бы показу.
	DemoResetCooldown = 10 * time.Minute
)

// DemoStatus — состояние демо-сервера для экрана входа.
type DemoStatus struct {
	Enabled bool       `json:"enabled"`
	ResetAt *time.Time `json:"reset_at,omitempty"` // когда данные заполнены последний раз
	// NextResetAt — следующий ночной сброс.
	NextResetAt *time.Time `json:"next_reset_at,omitempty"`
}

// Ошибки демо-режима.
var (
	// ErrDemoDisabled — сервер не в демо-режиме: ручки демо ведут себя как несуществующие.
	ErrDemoDisabled = errors.New("demo mode is disabled")
	// ErrDemoNotDemoDatabase — база не демо (имя без «_demo»): сброс запрещён.
	ErrDemoNotDemoDatabase = errors.New("база не демо: имя должно оканчиваться на _demo")
	// ErrDemoResetTooOften — кнопку сброса нажали раньше, чем через DemoResetCooldown.
	ErrDemoResetTooOften = errors.New("демо уже сбрасывали недавно: повторить можно через 10 минут")
	// ErrDemoResetRunning — сброс уже идёт.
	ErrDemoResetRunning = errors.New("сброс демо уже идёт")
)
