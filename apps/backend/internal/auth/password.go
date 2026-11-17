// Package auth - примитивы аутентификации: хеширование пароля (argon2) и JWT-токены.
// Пакет-лист (без зависимостей на другие внутренние слои): им пользуются и service, и middleware.
package auth

import "github.com/alexedwards/argon2id"

// HashPassword возвращает argon2id-хеш секрета в формате PHC (соль и параметры внутри строки).
// Зачем: секрет бейджа (последние 8 цифр) хранится только в виде хеша - при утечке БД
// исходный секрет не восстановить.
func HashPassword(secret string) (string, error) {
	return argon2id.CreateHash(secret, argon2id.DefaultParams)
}

// VerifyPassword сверяет секрет с сохранённым argon2-хешем (константное по времени сравнение внутри).
func VerifyPassword(secret, hash string) (bool, error) {
	return argon2id.ComparePasswordAndHash(secret, hash)
}
