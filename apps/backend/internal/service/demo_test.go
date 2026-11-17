package service

import (
	"io"
	"log/slog"
	"testing"
	"time"
)

// TestDemoNextReset - ночной сброс по Москве: сегодня, если время ещё не наступило, иначе
// завтра; неверное «ЧЧ:ММ» - 03:00.
func TestDemoNextReset(t *testing.T) {
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	cases := []struct {
		at, now, want string
	}{
		{"03:00", "2026-11-09T23:30:00Z", "2026-11-10T03:00:00+03:00"}, // 02:30 МСК - сегодня
		{"03:00", "2026-11-10T00:00:00Z", "2026-11-11T03:00:00+03:00"}, // ровно 03:00 - завтра
		{"23:15", "2026-11-09T10:00:00Z", "2026-11-09T23:15:00+03:00"},
		{"25:99", "2026-11-09T10:00:00Z", "2026-11-10T03:00:00+03:00"}, // неверное - 03:00
	}
	for _, c := range cases {
		s := NewDemoService(nil, nil, nil, c.at, log)
		now, _ := time.Parse(time.RFC3339, c.now)
		want, _ := time.Parse(time.RFC3339, c.want)
		if got := s.nextReset(now); !got.Equal(want) {
			t.Errorf("%s при %s: %s, ждали %s", c.at, c.now, got, want)
		}
	}
}
