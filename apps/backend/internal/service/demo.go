package service

import (
	"context"
	"fmt"
	"log/slog"
	"strconv"
	"strings"
	"sync"
	"time"

	"craftwms/internal/model"
)

// demoStore - то, что DemoService нужно от демо-базы.
type demoStore interface {
	IsDemoDatabase(ctx context.Context) (string, bool, error)
	RecreateSchema(ctx context.Context) error
	SeededAt(ctx context.Context) (time.Time, bool, error)
}

// demoLogin - вход без секрета под демо-пользователем.
type demoLogin interface {
	LoginWithoutSecret(ctx context.Context, login string) (TokenPair, error)
}

// DemoSeeder заполняет только что пересозданную базу демо-данными (internal/demo.Seed).
type DemoSeeder func(ctx context.Context, now time.Time) error

// demoMSK - время ночного сброса задаётся по Москве (без перехода на летнее время).
var demoMSK = time.FixedZone("MSK", 3*60*60)

// DemoService - демо-режим сервера (ADHOC-67): вход без пароля, состояние, сброс данных.
//
// Что: тот же бинарь, что на проде, включает режим переменной DEMO_MODE, но только на базе с
// именем «…_demo» (проверка в [DemoService.Init]). Иначе режим выключен, и ручки демо
// отвечают как несуществующие - вход без пароля на боевой базе невозможен даже по ошибке
// в конфигурации.
//
// Сброс: схема пересоздаётся, миграции накатываются заново, сидер заполняет данные. Один
// сброс за раз (мьютекс); кнопкой - не чаще [model.DemoResetCooldown].
type DemoService struct {
	store   demoStore
	auth    demoLogin
	seed    DemoSeeder
	resetAt time.Duration // смещение ночного сброса от полуночи по Москве
	now     func() time.Time
	log     *slog.Logger

	mu        sync.Mutex
	enabled   bool
	resetting bool
	lastReset time.Time
}

// NewDemoService собирает сервис. resetAt - «ЧЧ:ММ» по Москве; неверное значение - 03:00.
func NewDemoService(store demoStore, auth demoLogin, seed DemoSeeder, resetAt string, log *slog.Logger) *DemoService {
	return &DemoService{
		store: store, auth: auth, seed: seed, resetAt: parseClock(resetAt, 3*time.Hour),
		now: time.Now, log: log,
	}
}

// WithClock подменяет часы (тест: «прошло 10 минут»).
func (s *DemoService) WithClock(now func() time.Time) *DemoService {
	s.now = now
	return s
}

// Init включает режим, если база - демо, и заполняет её, если данных нет (первый запуск или
// оборванный сброс). Возвращает, включён ли режим.
func (s *DemoService) Init(ctx context.Context) (bool, error) {
	name, ok, err := s.store.IsDemoDatabase(ctx)
	if err != nil {
		return false, err
	}
	if !ok {
		s.log.Error("DEMO_MODE=true, но база не демо - демо-режим выключен",
			"database", name, "need_suffix", model.DemoDatabaseSuffix)
		return false, nil
	}
	s.mu.Lock()
	s.enabled = true
	s.mu.Unlock()
	if _, seeded, err := s.store.SeededAt(ctx); err != nil || !seeded {
		s.log.Info("демо-данных нет - заполняю", "error", err)
		return true, s.reset(ctx, false)
	}
	return true, nil
}

// Enabled - включён ли демо-режим.
func (s *DemoService) Enabled() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.enabled
}

// Status - состояние для экрана входа: включён ли режим, когда сброшен и когда следующий сброс.
func (s *DemoService) Status(ctx context.Context) model.DemoStatus {
	if !s.Enabled() {
		return model.DemoStatus{}
	}
	st := model.DemoStatus{Enabled: true}
	if at, ok, err := s.store.SeededAt(ctx); err == nil && ok {
		st.ResetAt = &at
	}
	next := s.nextReset(s.now())
	st.NextResetAt = &next
	return st
}

// Login - пара токенов демо-пользователя. Во время сброса - ErrInvalidCredentials: демо-
// пользователь ещё не включён.
func (s *DemoService) Login(ctx context.Context) (TokenPair, error) {
	if !s.Enabled() {
		return TokenPair{}, model.ErrDemoDisabled
	}
	return s.auth.LoginWithoutSecret(ctx, model.DemoUserLogin)
}

// Reset - сброс кнопкой администратора: не чаще [model.DemoResetCooldown].
func (s *DemoService) Reset(ctx context.Context) error {
	if !s.Enabled() {
		return model.ErrDemoDisabled
	}
	return s.reset(ctx, true)
}

// reset пересоздаёт базу и заполняет её. manual - сброс кнопкой: проверяется частота.
func (s *DemoService) reset(ctx context.Context, manual bool) error {
	s.mu.Lock()
	switch {
	case s.resetting:
		s.mu.Unlock()
		return model.ErrDemoResetRunning
	case manual && !s.lastReset.IsZero() && s.now().Sub(s.lastReset) < model.DemoResetCooldown:
		s.mu.Unlock()
		return model.ErrDemoResetTooOften
	}
	s.resetting = true
	s.mu.Unlock()
	defer func() {
		s.mu.Lock()
		s.resetting = false
		s.mu.Unlock()
	}()

	started := s.now()
	if err := s.store.RecreateSchema(ctx); err != nil {
		return fmt.Errorf("сброс демо: %w", err)
	}
	if err := s.seed(ctx, started); err != nil {
		return fmt.Errorf("сброс демо: %w", err)
	}
	s.mu.Lock()
	s.lastReset = s.now()
	s.mu.Unlock()
	s.log.Info("демо сброшено", "took", s.now().Sub(started).String(), "manual", manual)
	return nil
}

// Run - ночной сброс по расписанию до отмены контекста. Ошибка сброса пишется в журнал, а
// расписание продолжается: следующей ночью сброс попробует снова.
func (s *DemoService) Run(ctx context.Context) {
	for {
		wait := s.nextReset(s.now()).Sub(s.now())
		timer := time.NewTimer(wait)
		select {
		case <-ctx.Done():
			timer.Stop()
			return
		case <-timer.C:
			if err := s.reset(ctx, false); err != nil {
				s.log.Error("ночной сброс демо не удался", "error", err)
			}
		}
	}
}

// nextReset - ближайший момент ночного сброса после now.
func (s *DemoService) nextReset(now time.Time) time.Time {
	local := now.In(demoMSK)
	day := time.Date(local.Year(), local.Month(), local.Day(), 0, 0, 0, 0, demoMSK)
	next := day.Add(s.resetAt)
	if !next.After(local) {
		next = day.AddDate(0, 0, 1).Add(s.resetAt)
	}
	return next
}

// parseClock разбирает «ЧЧ:ММ» в смещение от полуночи; неверное значение - def.
func parseClock(v string, def time.Duration) time.Duration {
	hh, mm, ok := strings.Cut(strings.TrimSpace(v), ":")
	if !ok {
		return def
	}
	h, err1 := strconv.Atoi(hh)
	m, err2 := strconv.Atoi(mm)
	if err1 != nil || err2 != nil || h < 0 || h > 23 || m < 0 || m > 59 {
		return def
	}
	return time.Duration(h)*time.Hour + time.Duration(m)*time.Minute
}
