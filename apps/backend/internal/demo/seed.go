// Package demo — данные демо-сервера (ADHOC-67): выдуманный склад, по которому можно пройти
// все разделы ТСД и портала.
//
// Зачем данные заводятся через репозитории и операции очереди, а не готовым SQL-дампом: дамп
// отстал бы от схемы с первой же миграцией, а здесь приход, размещение, проблемы и реестр идут
// тем же кодом, что у склада. Поменялась операция — поменялись и демо-данные; разошлись —
// падает интеграционный тест сидера в CI, а не показ.
package demo

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"craftwms/internal/auth"
	"craftwms/internal/model"
	"craftwms/internal/repository"
)

// msk — время склада. Москва без перехода на летнее время, а в образе нет tzdata.
var msk = time.FixedZone("MSK", 3*60*60)

// seeder — состояние одного заполнения: id заведённого, нужные следующим шагам.
type seeder struct {
	ctx  context.Context
	pool *pgxpool.Pool
	now  time.Time // «сейчас» по Москве: даты партий и реестра — от него
	ops  *repository.OperationsRepository

	warehouseID string
	mainIWH     string            // внутренний склад «Основной»
	defectIWH   string            // «Брак»
	cells       map[string]string // адрес → id
	goods       map[string]string // код → id
	suppliers   []string
	adminID     string // демо-пользователь: заводится последним, но id нужен раньше
	annaID      string
	borisID     string
}

// Seed заполняет пустую (только что накатанную миграциями) базу демо-данными.
//
// Порядок: справочники → работники → ввод остатков → приёмка (задание на размещение) →
// проблемы склада → реестр на сборку (вчерашний собран и отгружен, завтрашний новый) →
// включение демо-пользователя. Он включается последним: по нему видно, что заполнение дошло до конца
// ([repository.DemoRepository.SeededAt]), и оборванный сброс не выглядит готовым.
func Seed(ctx context.Context, pool *pgxpool.Pool, now time.Time) error {
	s := &seeder{
		ctx: ctx, pool: pool, now: now.In(msk),
		ops:   repository.NewOperationsRepository(pool),
		cells: map[string]string{}, goods: map[string]string{},
	}
	steps := []struct {
		name string
		run  func() error
	}{
		{"справочники", s.catalog},
		{"ячейки", s.cellsAndRacks},
		{"работники", s.users},
		{"ввод остатков", s.stockEntry},
		{"приёмка", s.receipt},
		{"проблемы склада", s.problems},
		{"реестр на сборку", s.picking},
		{"демо-пользователь", s.demoUser},
	}
	for _, st := range steps {
		if err := st.run(); err != nil {
			return fmt.Errorf("демо-данные, %s: %w", st.name, err)
		}
	}
	return nil
}

// scan — одно значение запросом (id заведённого и т. п.).
func (s *seeder) scan(sql string, args ...any) (string, error) {
	var v string
	err := s.pool.QueryRow(s.ctx, sql, args...).Scan(&v)
	return v, err
}

// users — два кладовщика для истории: приёмку и сборку в демо делали «люди», а не админ.
// Войти под ними нельзя: секрет бейджа случайный и нигде не записан.
func (s *seeder) users() error {
	var err error
	if s.annaID, err = s.user("10000101", "Анна Кладовщикова", model.PositionWorkerID, true); err != nil {
		return err
	}
	if s.borisID, err = s.user("10000102", "Борис Сборщиков", model.PositionWorkerID, true); err != nil {
		return err
	}
	// Демо-пользователь нужен сразу - он автор ввода остатков и реестра, - но включается только
	// в demoUser: до конца заполнения войти в демо нельзя.
	s.adminID, err = s.user(model.DemoUserLogin, model.DemoUserName, model.PositionAdminID, false)
	return err
}

// user заводит работника с непригодным для входа секретом.
func (s *seeder) user(login, name, positionID string, active bool) (string, error) {
	secret := make([]byte, 16)
	if _, err := rand.Read(secret); err != nil {
		return "", err
	}
	hash, err := auth.HashPassword(hex.EncodeToString(secret))
	if err != nil {
		return "", err
	}
	return s.scan(`INSERT INTO users (login, password_hash, full_name, position_id, is_active)
		VALUES ($1, $2, $3, $4::uuid, $5) RETURNING id::text`, login, hash, name, positionID, active)
}

// demoUser отмечает конец заполнения: демо-пользователь включается, его created_at — время сброса.
func (s *seeder) demoUser() error {
	_, err := s.pool.Exec(s.ctx, `UPDATE users SET is_active = true, created_at = now() WHERE id = $1::uuid`,
		s.adminID)
	return err
}

// date — дата «сегодня минус days» строкой ISO: даты производства партий и документов.
func (s *seeder) date(days int) string {
	return s.now.AddDate(0, 0, -days).Format(time.DateOnly)
}
