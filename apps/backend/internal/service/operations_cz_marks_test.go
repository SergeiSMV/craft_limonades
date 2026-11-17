package service

import (
	"errors"
	"testing"

	"craftwms/internal/model"
)

// Марки строки движения (CZ-06): КИ по форме, без повторов в строке; пусто - строка без марок.
func TestLineMarks(t *testing.T) {
	got, err := lineMarks([]string{" 0104600000000017215A1 ", "0104600000000017215A2"})
	if err != nil || len(got) != 2 || got[0] != "0104600000000017215A1" {
		t.Fatalf("марки по форме: %v, %v", got, err)
	}
	if got, err := lineMarks(nil); err != nil || got != nil {
		t.Errorf("без марок: %v, %v", got, err)
	}
	if _, err := lineMarks([]string{"4600000000017"}); !errors.Is(err, model.ErrCZBadCode) {
		t.Errorf("ШК вместо марки: %v", err)
	}
	if _, err := lineMarks([]string{"0104600000000017215A1\x1d91EE"}); !errors.Is(err, model.ErrCZBadCode) {
		t.Errorf("марка с криптохвостом: %v", err)
	}
	if _, err := lineMarks([]string{"0104600000000017215A1", "0104600000000017215A1"}); !errors.Is(err, ErrInvalidPayload) {
		t.Errorf("повтор марки в строке: %v", err)
	}
}
