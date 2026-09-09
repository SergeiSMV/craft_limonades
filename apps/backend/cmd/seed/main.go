// Package main — сидер стартового администратора.
//
// Зачем: в пустой базе нет ни одного пользователя, значит войти нельзя (проблема курицы-яйца).
// Эта команда создаёт админа из ADMIN_BADGE, чтобы было под кем зайти и завести остальных.
// Запуск: make seed (DATABASE_URL и ADMIN_BADGE берутся из .env). Идемпотентно.
package main

import (
	"context"
	"log"
	"os"
	"time"

	"craftwms/internal/auth"
	"craftwms/internal/repository"
)

func main() {
	// 1. Читаем параметры из окружения (их подставляет `make seed` из .env).
	//    Без DSN и корректного бейджа сидить нечего — падаем сразу с понятной ошибкой.
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		log.Fatal("DATABASE_URL is required")
	}
	badge := os.Getenv("ADMIN_BADGE")
	if !isBadge(badge) {
		// Логин = первые 8 цифр, у таблицы users есть CHECK на 8 цифр — поэтому бейдж строго 16 цифр.
		log.Fatal("ADMIN_BADGE must be 16 digits")
	}
	fullName := os.Getenv("ADMIN_FULL_NAME")
	if fullName == "" {
		fullName = "Администратор" // ФИО опционально — даём разумный дефолт
	}

	// 2. Режем бейдж так же, как при логине: логин(8) + секрет(8).
	//    Секрет никогда не храним в открытом виде — только argon2-хеш (как и обычный вход).
	login, secret := badge[:8], badge[8:]
	hash, err := auth.HashPassword(secret)
	if err != nil {
		log.Fatalf("hash secret: %v", err)
	}

	// 3. Разовое подключение к БД с таймаутом (сид — короткая операция, не должна висеть).
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	pool, err := repository.NewPool(ctx, dsn)
	if err != nil {
		log.Fatalf("db pool: %v", err)
	}
	defer pool.Close()

	// 4. Идемпотентная вставка бейдж-админа: если логин уже есть — ничего не делаем.
	//    created сообщает, реально ли создали строку (для внятного лога при повторном запуске).
	userRepo := repository.NewUserRepository(pool)
	created, err := userRepo.CreateAdminIfNotExists(ctx, login, hash, fullName)
	if err != nil {
		log.Fatalf("seed admin: %v", err)
	}
	if created {
		log.Printf("badge admin seeded: login=%s", login)
	} else {
		log.Printf("badge admin already exists: login=%s (skipped)", login)
	}

	// 5. Опционально — admin с входом по логину/паролю (P1-01-1), если заданы
	//    ADMIN_USERNAME/ADMIN_PASSWORD. Так admin/менеджер входит со смартфона без бейджа.
	//
	// Молчать здесь нельзя: без этих переменных сид отрабатывает «успешно», а в веб-портал
	// войти некем — вход по паролю ищет по колонке username, которой у бейдж-админа нет.
	// Снаружи это неотличимо от неверного пароля: сервис намеренно отвечает одинаково.
	if os.Getenv("ADMIN_USERNAME") == "" {
		log.Print("WARNING: ADMIN_USERNAME/ADMIN_PASSWORD не заданы — админ портала НЕ создан, войти в веб-портал будет нечем")
	}
	if username := os.Getenv("ADMIN_USERNAME"); username != "" {
		password := os.Getenv("ADMIN_PASSWORD")
		if len(username) < 3 {
			log.Fatal("ADMIN_USERNAME must be at least 3 chars")
		}
		if len(password) < 8 {
			log.Fatal("ADMIN_PASSWORD must be at least 8 chars")
		}
		pwHash, err := auth.HashPassword(password)
		if err != nil {
			log.Fatalf("hash password: %v", err)
		}
		createdU, err := userRepo.CreateUsernameAdminIfNotExists(ctx, username, pwHash, fullName)
		if err != nil {
			log.Fatalf("seed username admin: %v", err)
		}
		if createdU {
			log.Printf("username admin seeded: username=%s", username)
		} else {
			log.Printf("username admin already exists: username=%s (skipped)", username)
		}
	}
}

// isBadge проверяет, что строка — ровно 16 десятичных цифр.
func isBadge(s string) bool {
	if len(s) != 16 {
		return false
	}
	for _, c := range s {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}
