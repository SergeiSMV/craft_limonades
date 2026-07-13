// Package model — сущности предметной области (чистые структуры без внешних зависимостей).
package model

import "time"

// Роли пользователя. employee — кладовщик на ТСД; admin — управление пользователями.
const (
	RoleEmployee = "employee"
	RoleAdmin    = "admin"
)

// User — учётная запись. Поля с тегами db — для скана строк pgx (RowToStructByName).
type User struct {
	ID           string    `db:"id"`            // uuid (как текст)
	Login        string    `db:"login"`         // первые 8 цифр бейджа
	PasswordHash string    `db:"password_hash"` // argon2-хеш секрета (последних 8 цифр)
	FullName     string    `db:"full_name"`     // ФИО → «исполнитель» в отчётах
	Role         string    `db:"role"`          // employee | admin
	IsActive     bool      `db:"is_active"`     // блокировка/«удаление» = false
	CreatedAt    time.Time `db:"created_at"`
	UpdatedAt    time.Time `db:"updated_at"`
}
