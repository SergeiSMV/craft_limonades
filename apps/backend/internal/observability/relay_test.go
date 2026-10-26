package observability

import (
	"errors"
	"testing"
)

// Заголовок конверта: `dsn` убирается, остальное и элементы — как были; без `dsn` и без
// элементов — тоже конверт; не JSON-объект — не конверт (ADHOC-47).
func TestStripEnvelopeDSN(t *testing.T) {
	cases := []struct {
		name, in, want string
		err            error
	}{
		{name: "с dsn и элементом", in: "{\"dsn\":\"https://wms@h/1\",\"event_id\":\"e1\"}\n{\"type\":\"event\"}\n{}\n",
			want: "{\"event_id\":\"e1\"}\n{\"type\":\"event\"}\n{}\n"},
		{name: "без dsn — как есть", in: "{\"event_id\":\"e1\"}\n{}", want: "{\"event_id\":\"e1\"}\n{}"},
		{name: "только заголовок", in: "{\"dsn\":\"x\"}", want: "{}"},
		{name: "не объект", in: "[1]\n{}", err: ErrBadEnvelope},
		{name: "не JSON", in: "привет", err: ErrBadEnvelope},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := StripEnvelopeDSN([]byte(tc.in))
			if tc.err != nil {
				if !errors.Is(err, tc.err) {
					t.Fatalf("ждали %v, получили %v", tc.err, err)
				}
				return
			}
			if err != nil || string(got) != tc.want {
				t.Fatalf("получили %q, %v; ждали %q", got, err, tc.want)
			}
		})
	}
}
