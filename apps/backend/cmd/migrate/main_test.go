package main

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/golang-migrate/migrate/v4"
	"github.com/golang-migrate/migrate/v4/source/iofs"
	"github.com/jackc/pgx/v5"
	"github.com/testcontainers/testcontainers-go"
	tcpostgres "github.com/testcontainers/testcontainers-go/modules/postgres"
	"github.com/testcontainers/testcontainers-go/wait"

	"craftwms/migrations"
)

// TestPendingMigrations — `migrate pending` (ADHOC-37): по нему update.sh решает, снимать ли
// дамп перед миграциями. Пустая база, отставшая схема и «грязная» версия — «есть что
// применять», актуальная — нет.
func TestPendingMigrations(t *testing.T) {
	testcontainers.SkipIfProviderIsNotHealthy(t) // нет Docker → t.Skip, а не падение

	ctx := context.Background()
	ctr, err := tcpostgres.Run(ctx, "postgres:16-alpine",
		tcpostgres.WithDatabase("wms"),
		tcpostgres.WithUsername("wms"),
		tcpostgres.WithPassword("wms"),
		testcontainers.WithWaitStrategy(
			wait.ForLog("database system is ready to accept connections").
				WithOccurrence(2).WithStartupTimeout(60*time.Second)),
	)
	testcontainers.CleanupContainer(t, ctr)
	if err != nil {
		t.Fatalf("запуск postgres-контейнера: %v", err)
	}
	dsn, err := ctr.ConnectionString(ctx, "sslmode=disable")
	if err != nil {
		t.Fatalf("connection string: %v", err)
	}

	src, err := iofs.New(migrations.FS, ".")
	if err != nil {
		t.Fatalf("источник: %v", err)
	}
	m, err := migrate.NewWithSourceInstance("iofs", src, strings.Replace(dsn, "postgres://", "pgx5://", 1))
	if err != nil {
		t.Fatalf("init migrate: %v", err)
	}
	latestSrc, err := iofs.New(migrations.FS, ".")
	if err != nil {
		t.Fatalf("источник: %v", err)
	}
	latest, err := latestVersion(latestSrc)
	if err != nil {
		t.Fatalf("последняя миграция: %v", err)
	}
	if latest < 2 {
		t.Fatalf("последняя миграция %d — тесту нужно хотя бы две", latest)
	}

	check := func(want bool, stage string) {
		t.Helper()
		got, why, err := pendingMigrations(m, latest)
		if err != nil {
			t.Fatalf("%s: %v", stage, err)
		}
		if got != want {
			t.Fatalf("%s: pending = %v (%s), ждали %v", stage, got, why, want)
		}
	}

	check(true, "пустая база")

	if err := m.Steps(1); err != nil {
		t.Fatalf("первая миграция: %v", err)
	}
	check(true, "схема отстаёт")

	if err := m.Up(); err != nil {
		t.Fatalf("migrate up: %v", err)
	}
	check(false, "схема актуальна")

	// «Грязная» версия — как после миграции, упавшей на середине: golang-migrate ставит флаг
	// в schema_migrations до применения и снимает после.
	conn, err := pgx.Connect(ctx, dsn)
	if err != nil {
		t.Fatalf("подключение: %v", err)
	}
	t.Cleanup(func() { _ = conn.Close(ctx) })
	if _, err := conn.Exec(ctx, "UPDATE schema_migrations SET dirty = true"); err != nil {
		t.Fatalf("пометка dirty: %v", err)
	}
	check(true, "версия «грязная»")
}
