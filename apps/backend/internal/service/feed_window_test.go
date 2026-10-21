package service

import (
	"errors"
	"testing"
)

// Период и курсор ленты разбираются одинаково для заданий и истории перемещений (ADHOC-28).
func TestParseFeedWindow(t *testing.T) {
	const id = "11111111-1111-4111-8111-111111111111"
	w, err := parseFeedWindow("2026-10-01", "2026-10-14", "2026-10-14T09:00:00.123456Z", id, 0, 30, 100)
	if err != nil {
		t.Fatalf("верный фильтр: %v", err)
	}
	// День «по» включается целиком: граница — полночь следующего дня по Москве (21:00 UTC).
	if w.From.UTC().Format("2006-01-02 15:04") != "2026-09-30 21:00" ||
		w.To.UTC().Format("2006-01-02 15:04") != "2026-10-14 21:00" ||
		w.Before.Nanosecond() != 123456000 || w.BeforeID != id || w.Limit != 30 {
		t.Errorf("окно: %+v", w)
	}
	if w, _ := parseFeedWindow("", "", "", "", 500, 30, 100); w.Limit != 100 || w.From != nil || w.Before != nil {
		t.Errorf("пустой фильтр и лимит сверх предела: %+v", w)
	}

	for name, args := range map[string][4]string{
		"дата не по формату":  {"01-10-2026", "", "", ""},
		"курсор без id":       {"", "", "2026-10-14T09:00:00Z", ""},
		"курсор не по форме":  {"", "", "вчера", id},
		"id курсора не UUID":  {"", "", "2026-10-14T09:00:00Z", "x"},
		"конец не по формату": {"", "2026.10.14", "", ""},
	} {
		if _, err := parseFeedWindow(args[0], args[1], args[2], args[3], 0, 30, 100); !errors.Is(err, errInvalidFeedWindow) {
			t.Errorf("%s: %v", name, err)
		}
	}
}
