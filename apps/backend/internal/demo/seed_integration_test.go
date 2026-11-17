package demo

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"craftwms/internal/auth"
	"craftwms/internal/model"
	"craftwms/internal/repository"
	"craftwms/internal/service"
	"craftwms/internal/testutil"
)

// TestDemo_resetSeedsAndLogsIn - демо-сервер целиком на живой базе: на базе без «_demo» режим
// не включается и схему не стирает; на демо-базе пустая база заполняется при старте (схема
// заново, миграции, сидер), демо-пользователь входит без пароля, сброс кнопкой не чаще раза
// в 10 минут и снова даёт те же данные.
//
// Это и страховка сидера: он идёт через операции склада, и разошедшаяся с ним миграция или
// правка операции роняет этот тест в CI, а не показ на демо-сервере.
func TestDemo_resetSeedsAndLogsIn(t *testing.T) {
	ctx := context.Background()
	prod := testutil.StartPostgres(t) // база «wms» - как боевая, не демо
	log := slog.New(slog.NewTextHandler(io.Discard, nil))

	// 1. Не демо-база: режим выключен, схема цела.
	prodRepo := repository.NewDemoRepository(prod, prod.Config().ConnString())
	on, err := newDemoService(prod, prodRepo, log).Init(ctx)
	if err != nil || on {
		t.Fatalf("на базе без _demo режим включился: on=%v err=%v", on, err)
	}
	if err := prodRepo.RecreateSchema(ctx); !errors.Is(err, model.ErrDemoNotDemoDatabase) {
		t.Fatalf("сброс не демо-базы: %v", err)
	}

	// 2. Демо-база рядом в том же контейнере.
	if _, err := prod.Exec(ctx, `CREATE DATABASE wms_demo`); err != nil {
		t.Fatal(err)
	}
	dsn := strings.Replace(prod.Config().ConnString(), "/wms?", "/wms_demo?", 1)
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	svc := newDemoService(pool, repository.NewDemoRepository(pool, dsn), log)
	if on, err := svc.Init(ctx); err != nil || !on {
		t.Fatalf("демо не включилось: on=%v err=%v", on, err)
	}
	checkSeeded(t, pool)

	pair, err := svc.Login(ctx)
	if err != nil || pair.Access == "" {
		t.Fatalf("вход в демо: %v", err)
	}
	if st := svc.Status(ctx); !st.Enabled || st.ResetAt == nil || st.NextResetAt == nil {
		t.Fatalf("состояние демо: %+v", st)
	}

	// 3. Сброс кнопкой: старт сам был сбросом - повтор сразу отклоняется, через 10 минут проходит.
	if err := svc.Reset(ctx); !errors.Is(err, model.ErrDemoResetTooOften) {
		t.Fatalf("частый сброс: %v", err)
	}
	later := time.Now().Add(model.DemoResetCooldown + time.Minute)
	svc.WithClock(func() time.Time { return later })
	if err := svc.Reset(ctx); err != nil {
		t.Fatalf("сброс кнопкой: %v", err)
	}
	checkSeeded(t, pool)
}

// newDemoService - сервис, как его собирает main, с сидером этого пакета.
func newDemoService(pool *pgxpool.Pool, repo *repository.DemoRepository, log *slog.Logger) *service.DemoService {
	tokens := auth.NewTokenManager("demo-test-secret", time.Hour, time.Hour)
	authSvc := service.NewAuthService(repository.NewUserRepository(pool), tokens, nil)
	return service.NewDemoService(repo, authSvc,
		func(ctx context.Context, now time.Time) error { return Seed(ctx, pool, now) }, "03:00", log)
}

// checkSeeded - в базе то, что обещает демо: справочник, остатки, задание на размещение,
// проблемы, заказы сборки (один отгружен), включённый демо-пользователь.
func checkSeeded(t *testing.T, pool *pgxpool.Pool) {
	t.Helper()
	for _, c := range []struct {
		name, sql string
		want      int
	}{
		{"товары", `SELECT count(*) FROM goods`, len(demoGoods)},
		{"ШК", `SELECT count(*) FROM barcodes`, len(demoGoods)},
		{"задание на размещение", `SELECT count(*) FROM warehouse_tasks WHERE kind = 'putaway' AND status = 'new'`, 1},
		{"проблемы", `SELECT count(*) FROM warehouse_problems WHERE status = 'open'`, 2},
		{"заказы сборки", `SELECT count(*) FROM picking_orders`, 6},
		{"отгружен", `SELECT count(*) FROM picking_orders WHERE status = 'shipped'`, 1},
		{"демо-пользователь", `SELECT count(*) FROM users WHERE login = '99999999' AND is_active`, 1},
	} {
		var got int
		if err := pool.QueryRow(context.Background(), c.sql).Scan(&got); err != nil {
			t.Fatalf("%s: %v", c.name, err)
		}
		if got != c.want {
			t.Errorf("%s: %d, ждали %d", c.name, got, c.want)
		}
	}
	var stock int
	if err := pool.QueryRow(context.Background(), `SELECT coalesce(sum(qty), 0)::int FROM stock`).Scan(&stock); err != nil || stock == 0 {
		t.Errorf("остатков нет: %d, %v", stock, err)
	}
}
