package service

import (
	"errors"
	"strings"
	"testing"
	"time"

	"craftwms/internal/model"
)

// Документ поставщика (ADHOC-23): номер обязателен («б/н» - тоже номер), дата - DD-MM-YYYY
// и не в будущем, с запасом в сутки на разницу UTC и Москвы.
func TestParseSupplierDoc(t *testing.T) {
	now := time.Date(2026, 10, 9, 22, 30, 0, 0, time.UTC) // в Москве уже 10 октября

	doc, err := parseSupplierDoc("  ТН-1042/2 ", "09-10-2026", now)
	if err != nil || doc.Number != "ТН-1042/2" || !doc.Date.Equal(time.Date(2026, 10, 9, 0, 0, 0, 0, time.UTC)) {
		t.Errorf("обычная накладная: %+v, %v", doc, err)
	}
	if _, err := parseSupplierDoc("б/н", "10-10-2026", now); err != nil {
		t.Errorf("«б/н» и сегодняшняя по Москве дата: %v", err)
	}

	for _, tc := range []struct {
		name, number, date string
		want               error
	}{
		{"пустой номер", "  ", "01-10-2026", model.ErrEmptyDocNumber},
		{"длинный номер", strings.Repeat("Я", 51), "01-10-2026", model.ErrDocNumberTooLong},
		{"нет даты", "1", "", model.ErrInvalidDocDate},
		{"ISO вместо DD-MM-YYYY", "1", "2026-10-01", model.ErrInvalidDocDate},
		{"дата в будущем", "1", "12-10-2026", model.ErrInvalidDocDate},
	} {
		if _, err := parseSupplierDoc(tc.number, tc.date, now); !errors.Is(err, tc.want) {
			t.Errorf("%s: %v, ожидалось %v", tc.name, err, tc.want)
		}
	}
}
