// Package main - раннер миграций схемы БД (golang-migrate + встроенные .sql).
//
// Использование:  migrate up | down | pending
// DSN берётся из переменной окружения DATABASE_URL.
//
// `pending` ничего не меняет и отвечает кодом выхода, есть ли что применять (ADHOC-37):
// 0 - есть (или база пустая / «грязная» после упавшей миграции), 3 - схема актуальна,
// 1 - ошибка. По нему deploy/update.sh решает, снимать ли дамп перед `up`.
// Миграции применяются явной командой (make migrate-up / migrate-down), а не на старте
// сервиса - так безопаснее при нескольких инстансах.
package main

import (
	"errors"
	"fmt"
	"io/fs"
	"log"
	"os"
	"strings"

	"github.com/golang-migrate/migrate/v4"
	_ "github.com/golang-migrate/migrate/v4/database/pgx/v5" // драйвер БД, схема pgx5://
	"github.com/golang-migrate/migrate/v4/source"
	"github.com/golang-migrate/migrate/v4/source/iofs"

	"craftwms/migrations"
)

func main() {
	if len(os.Args) < 2 {
		log.Fatal("usage: migrate up|down|pending")
	}
	cmd := os.Args[1]

	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		log.Fatal("DATABASE_URL is required")
	}
	// golang-migrate ждёт схему pgx5://; приложение использует postgres:// - приводим.
	dsn = strings.Replace(dsn, "postgres://", "pgx5://", 1)
	dsn = strings.Replace(dsn, "postgresql://", "pgx5://", 1)

	// Источник миграций - встроенная файловая система.
	src, err := iofs.New(migrations.FS, ".")
	if err != nil {
		log.Fatalf("источник миграций: %v", err)
	}

	m, err := migrate.NewWithSourceInstance("iofs", src, dsn)
	if err != nil {
		log.Fatalf("инициализация migrate: %v", err)
	}

	switch cmd {
	case "pending":
		// Отдельный экземпляр источника: первый уже отдан migrate и читается им.
		latestSrc, err := iofs.New(migrations.FS, ".")
		if err != nil {
			log.Fatalf("источник миграций: %v", err)
		}
		latest, err := latestVersion(latestSrc)
		if err != nil {
			log.Fatalf("последняя миграция: %v", err)
		}
		pending, why, err := pendingMigrations(m, latest)
		if err != nil {
			log.Fatalf("migrate pending: %v", err)
		}
		log.Printf("migrate pending: %s", why)
		if !pending {
			os.Exit(exitUpToDate)
		}
		return
	case "up":
		err = m.Up()
	case "down":
		err = m.Down()
	default:
		log.Fatalf("неизвестная команда %q (используйте up|down|pending)", cmd)
	}
	// ErrNoChange - «нечего применять/откатывать», это не ошибка.
	if err != nil && !errors.Is(err, migrate.ErrNoChange) {
		log.Fatalf("migrate %s: %v", cmd, err)
	}
	log.Printf("migrate %s: ok", cmd)
}

// exitUpToDate - код выхода `pending`, когда применять нечего. Не 1: единицу отдаёт
// log.Fatal, и ошибку нельзя было бы отличить от «схема актуальна».
const exitUpToDate = 3

// latestVersion - номер последней миграции в источнике.
//
// golang-migrate отдаёт версии только цепочкой First → Next, поэтому идём до конца.
func latestVersion(src source.Driver) (uint, error) {
	v, err := src.First()
	if err != nil {
		return 0, err
	}
	for {
		next, err := src.Next(v)
		if errors.Is(err, fs.ErrNotExist) {
			return v, nil
		}
		if err != nil {
			return 0, err
		}
		v = next
	}
}

// pendingMigrations - есть ли что применять к базе: версия базы против [latest].
//
// Пустая база и «грязная» (миграция упала на середине) считаются «есть»: перед `up` в обоих
// случаях нужен дамп, а «грязную» `up` всё равно откажется трогать без ручного разбора.
// Второе значение - причина для журнала обновления.
func pendingMigrations(m *migrate.Migrate, latest uint) (bool, string, error) {
	v, dirty, err := m.Version()
	switch {
	case errors.Is(err, migrate.ErrNilVersion):
		return true, fmt.Sprintf("база без схемы, к применению до %d", latest), nil
	case err != nil:
		return false, "", err
	case dirty:
		return true, fmt.Sprintf("версия %d «грязная» (миграция не завершилась)", v), nil
	case v < latest:
		return true, fmt.Sprintf("версия %d, к применению до %d", v, latest), nil
	default:
		return false, fmt.Sprintf("версия %d актуальна", v), nil
	}
}
