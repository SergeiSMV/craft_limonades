package handler_test

import (
	"context"

	"craftwms/internal/model"
)

// fakeRights — доступ по id пользователя для тестов роутера без базы (ADHOC-49): тот же
// контракт, что у репозитория пользователей. Неизвестный id — заблокирован.
type fakeRights map[string]model.Access

func (f fakeRights) UserAccess(_ context.Context, id string) (model.Access, error) {
	return f[id], nil
}

// testRights — «Администратор» (…a1) и кладовщик с правами ТСД (…b1): id те же, что у
// токенов в тестах без базы.
var testRights = fakeRights{
	"00000000-0000-4000-8000-0000000000a1": {Rights: model.Rights, System: true, Active: true},
	"00000000-0000-4000-8000-0000000000b1": {
		Rights: []string{model.RightTSDReceipt, model.RightTSDStockView}, Active: true,
	},
}
