package service

import (
	"context"
	"errors"
	"strings"
	"testing"

	"craftwms/internal/model"
)

type fakeIwhRepo struct{ created []string }

func (f *fakeIwhRepo) All(context.Context) ([]model.InternalWarehouse, error) { return nil, nil }
func (f *fakeIwhRepo) Create(_ context.Context, code, name string) (model.InternalWarehouse, error) {
	f.created = append(f.created, code+"|"+name)
	return model.InternalWarehouse{Code: code, Name: name}, nil
}
func (f *fakeIwhRepo) Update(_ context.Context, _ string, _ *string, _ *bool) (model.InternalWarehouse, error) {
	return model.InternalWarehouse{}, nil
}
func (f *fakeIwhRepo) Delete(context.Context, string) error { return nil }

// ADHOC-29: код и имя склада проверяются до базы; код приводится к верхнему регистру.
func TestInternalWarehouseService_validation(t *testing.T) {
	repo := &fakeIwhRepo{}
	svc := NewInternalWarehouseService(repo)
	ctx := context.Background()

	if _, err := svc.Create(ctx, " return_1 ", "  Возврат "); err != nil {
		t.Fatalf("верный склад: %v", err)
	}
	if repo.created[0] != "RETURN_1|Возврат" {
		t.Errorf("приведение: %v", repo.created)
	}
	for name, args := range map[string][2]string{
		"код с пробелом":  {"MY WH", "Склад"},
		"код кириллицей":  {"БРАК2", "Склад"},
		"код длиннее 20":  {strings.Repeat("A", 21), "Склад"},
		"пустое имя":      {"OK", "   "},
		"имя длиннее 100": {"OK", strings.Repeat("я", 101)},
		"пустой код":      {"", "Склад"},
	} {
		if _, err := svc.Create(ctx, args[0], args[1]); !errors.Is(err, ErrInvalidInternalWarehouse) {
			t.Errorf("%s: %v", name, err)
		}
	}
	blank := " "
	if _, err := svc.Update(ctx, "11111111-1111-4111-8111-111111111111", &blank, nil); !errors.Is(err, ErrInvalidInternalWarehouse) {
		t.Errorf("переименовать в пустое: %v", err)
	}
	if err := svc.Delete(ctx, "x"); !errors.Is(err, ErrInvalidInternalWarehouse) {
		t.Errorf("id не UUID: %v", err)
	}
}
