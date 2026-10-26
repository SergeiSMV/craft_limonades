package repository_test

import (
	"context"
	"testing"

	"craftwms/internal/model"
	"craftwms/internal/testutil"
)

// ADHOC-49: схема должностей держит свои правила сама — стартовые должности на месте,
// пользователь без должности становится кладовщиком, права — только из списка, системная
// должность одна, должность с пользователями не удалить.
func TestPositionsSchema(t *testing.T) {
	pool := testutil.StartPostgres(t)
	ctx := context.Background()
	exec := func(sql string, args ...any) error {
		_, err := pool.Exec(ctx, sql, args...)
		return err
	}

	var admin, worker string
	mustScan(t, pool, `SELECT string_agg(name || ':' || is_system::text || ':' || cardinality(rights)::text, ' ' ORDER BY name)
		FROM positions`, &admin)
	if admin != "Администратор:true:9 Кладовщик:false:1" {
		t.Errorf("стартовые должности: %s", admin)
	}
	mustScan(t, pool, `INSERT INTO users (login, password_hash, full_name) VALUES ('10000077','x','Без должности')
		RETURNING position_id::text`, &worker)
	if worker != model.PositionWorkerID {
		t.Errorf("должность по умолчанию: %s, ожидался «Кладовщик»", worker)
	}

	for _, c := range []struct{ what, sql string }{
		{"неизвестное право", `INSERT INTO positions (name, rights) VALUES ('Склад', ARRAY['fly'])`},
		{"вторая системная", `INSERT INTO positions (name, is_system) VALUES ('Ещё админ', true)`},
		{"пустое название", `INSERT INTO positions (name) VALUES ('  ')`},
		{"удалить должность с пользователем", `DELETE FROM positions WHERE id = '` + model.PositionWorkerID + `'`},
	} {
		if err := exec(c.sql); err == nil {
			t.Errorf("%s: база приняла", c.what)
		}
	}
}
