// Package main — раннер миграций схемы БД (golang-migrate + встроенные .sql).
//
// Использование:  migrate up | down
// DSN берётся из переменной окружения DATABASE_URL.
// Миграции применяются явной командой (make migrate-up / migrate-down), а не на старте
// сервиса — так безопаснее при нескольких инстансах.
package main

import (
	"errors"
	"log"
	"os"
	"strings"

	"github.com/golang-migrate/migrate/v4"
	_ "github.com/golang-migrate/migrate/v4/database/pgx/v5" // драйвер БД, схема pgx5://
	"github.com/golang-migrate/migrate/v4/source/iofs"

	"craftwms/migrations"
)

func main() {
	if len(os.Args) < 2 {
		log.Fatal("usage: migrate up|down")
	}
	cmd := os.Args[1]

	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		log.Fatal("DATABASE_URL is required")
	}
	// golang-migrate ждёт схему pgx5://; приложение использует postgres:// — приводим.
	dsn = strings.Replace(dsn, "postgres://", "pgx5://", 1)
	dsn = strings.Replace(dsn, "postgresql://", "pgx5://", 1)

	// Источник миграций — встроенная файловая система.
	src, err := iofs.New(migrations.FS, ".")
	if err != nil {
		log.Fatalf("источник миграций: %v", err)
	}

	m, err := migrate.NewWithSourceInstance("iofs", src, dsn)
	if err != nil {
		log.Fatalf("инициализация migrate: %v", err)
	}

	switch cmd {
	case "up":
		err = m.Up()
	case "down":
		err = m.Down()
	default:
		log.Fatalf("неизвестная команда %q (используйте up|down)", cmd)
	}
	// ErrNoChange — «нечего применять/откатывать», это не ошибка.
	if err != nil && !errors.Is(err, migrate.ErrNoChange) {
		log.Fatalf("migrate %s: %v", cmd, err)
	}
	log.Printf("migrate %s: ok", cmd)
}
