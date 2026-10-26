package handler_test

import (
	"context"

	"craftwms/internal/model"
)

// fakeRights — права по id пользователя для тестов роутера без базы (ADHOC-49): тот же
// контракт, что у репозитория пользователей. Неизвестный id — заблокирован.
type fakeRights map[string][]string

func (f fakeRights) UserRights(_ context.Context, id string) ([]string, bool, error) {
	r, ok := f[id]
	return r, ok, nil
}

// testRights — админ (…a1) со всеми правами и кладовщик (…b1) с работой на ТСД: id те же,
// что у токенов в тестах без базы.
var testRights = fakeRights{
	"00000000-0000-4000-8000-0000000000a1": model.Rights,
	"00000000-0000-4000-8000-0000000000b1": {model.RightTSD},
}
