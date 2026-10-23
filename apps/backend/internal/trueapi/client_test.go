package trueapi

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"craftwms/internal/czsigner"
	"craftwms/internal/model"
)

// Тесты CZ-02, шаг 2: клиент против фальшивого True API и подставного подписанта.

var quietLog = slog.New(slog.NewTextHandler(io.Discard, nil))

// t0 — «сейчас» тестов; токены фальшивого ЧЗ живут 10 часов от него.
var t0 = time.Date(2026, 10, 23, 9, 0, 0, 0, time.UTC)

// clock — подменяемое время клиента.
type clock struct {
	mu  sync.Mutex
	now time.Time
}

func (c *clock) Now() time.Time      { c.mu.Lock(); defer c.mu.Unlock(); return c.now }
func (c *clock) Add(d time.Duration) { c.mu.Lock(); c.now = c.now.Add(d); c.mu.Unlock() }
func newClock() *clock               { return &clock{now: t0} }
func jwt(exp time.Time, n int64) string {
	return fakeJWT(fmt.Sprintf(`{"exp":%d,"n":%d}`, exp.Unix(), n))
}

func fakeJWT(payload string) string {
	enc := base64.RawURLEncoding.EncodeToString
	return enc([]byte(`{"alg":"none"}`)) + "." + enc([]byte(payload)) + "." + enc([]byte("sig"))
}

// stubSigner — подпись без КриптоПро: "SIG:" + данные; err — отказ.
type stubSigner struct {
	calls atomic.Int64
	err   error
}

func (s *stubSigner) Sign(_ context.Context, data []byte) ([]byte, error) {
	s.calls.Add(1)
	if s.err != nil {
		return nil, s.err
	}
	return append([]byte("SIG:"), data...), nil
}
func (s *stubSigner) Health(context.Context) error { return s.err }

// fakeAPI — фальшивый True API: вход с проверкой подписи и cises/info.
type fakeAPI struct {
	t         *testing.T
	signIns   atomic.Int64
	signInErr int            // код отказа simpleSignIn; 0 — выдать токен
	infoCode  func() int     // код ответа cises/info; nil — 200
	infoBody  string         // тело 200 для cises/info
	lastCodes []string       // коды последнего cises/info
	tokens    map[string]int // выданные токены
	mu        sync.Mutex
}

func newFakeAPI(t *testing.T) (*fakeAPI, *httptest.Server) {
	f := &fakeAPI{t: t, tokens: map[string]int{}}
	srv := httptest.NewServer(http.HandlerFunc(f.serve))
	t.Cleanup(srv.Close)
	return f, srv
}

func (f *fakeAPI) serve(w http.ResponseWriter, r *http.Request) {
	switch r.URL.Path {
	case "/api/v3/true-api/auth/key":
		_, _ = io.WriteString(w, `{"uuid":"u-1","data":"CHALLENGE"}`)
	case "/api/v3/true-api/auth/simpleSignIn":
		var req struct{ UUID, Data string }
		_ = json.NewDecoder(r.Body).Decode(&req)
		sig, _ := base64.StdEncoding.DecodeString(req.Data)
		if req.UUID != "u-1" || string(sig) != "SIG:CHALLENGE" {
			f.t.Errorf("bad sign-in: uuid=%q sig=%q", req.UUID, sig)
		}
		if f.signInErr != 0 {
			w.WriteHeader(f.signInErr)
			_, _ = io.WriteString(w, `{"error_message":"МЧД не найдена"}`)
			return
		}
		n := f.signIns.Add(1)
		token := jwt(t0.Add(10*time.Hour), n)
		f.mu.Lock()
		f.tokens[token] = int(n)
		f.mu.Unlock()
		_, _ = fmt.Fprintf(w, `{"token":%q}`, token)
	case "/api/v3/true-api/cises/info":
		f.mu.Lock()
		_, known := f.tokens[strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")]
		_ = json.NewDecoder(r.Body).Decode(&f.lastCodes)
		f.mu.Unlock()
		if !known {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		code := http.StatusOK
		if f.infoCode != nil {
			code = f.infoCode()
		}
		w.WriteHeader(code)
		if code == http.StatusOK {
			_, _ = io.WriteString(w, f.infoBody)
		} else {
			_, _ = io.WriteString(w, `{"error_message":"отказ"}`)
		}
	default:
		http.NotFound(w, r)
	}
}

func newClient(srv *httptest.Server, s Signer, clk *clock) *Client {
	return New(Options{
		BaseURL: srv.URL + "/api/v3/true-api/",
		Signer:  s,
		Log:     quietLog,
		Now:     clk.Now,
	})
}

func TestTokenCachedAndRefreshedBeforeExpiry(t *testing.T) {
	api, srv := newFakeAPI(t)
	signer, clk := &stubSigner{}, newClock()
	c := newClient(srv, signer, clk)
	ctx := context.Background()

	first, err := c.Token(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if again, _ := c.Token(ctx); again != first || api.signIns.Load() != 1 {
		t.Fatalf("token not cached: sign-ins=%d", api.signIns.Load())
	}
	if exp, ok := c.TokenExpiry(); !ok || !exp.Equal(t0.Add(10*time.Hour)) {
		t.Fatalf("expiry = %v, %v", exp, ok)
	}

	// За 59 минут до истечения — уже порог обновления (час): входим заново.
	clk.Add(9*time.Hour + time.Minute)
	second, err := c.Token(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if second == first || api.signIns.Load() != 2 || signer.calls.Load() != 2 {
		t.Fatalf("token not refreshed: sign-ins=%d signs=%d", api.signIns.Load(), signer.calls.Load())
	}
}

func TestTokenRefreshFailureKeepsValidToken(t *testing.T) {
	_, srv := newFakeAPI(t)
	signer, clk := &stubSigner{}, newClock()
	c := newClient(srv, signer, clk)
	ctx := context.Background()

	first, err := c.Token(ctx)
	if err != nil {
		t.Fatal(err)
	}
	signer.err = fmt.Errorf("%w: connection refused", model.ErrCZSignerUnavailable)

	// В окне обновления, но токен ещё годен — работаем на старом.
	clk.Add(9*time.Hour + 30*time.Minute)
	if got, err := c.Token(ctx); err != nil || got != first {
		t.Fatalf("got %q, %v; want old token", got, err)
	}
	// До истечения меньше минуты — старый не отдаём, отдаём причину.
	clk.Add(29*time.Minute + 30*time.Second)
	if _, err := c.Token(ctx); !errors.Is(err, model.ErrCZSignerUnavailable) {
		t.Fatalf("err = %v, want ErrCZSignerUnavailable", err)
	}
}

func TestTokenConcurrentCallersSignOnce(t *testing.T) {
	api, srv := newFakeAPI(t)
	c := newClient(srv, &stubSigner{}, newClock())

	var wg sync.WaitGroup
	for range 20 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, err := c.Token(context.Background()); err != nil {
				t.Error(err)
			}
		}()
	}
	wg.Wait()
	if n := api.signIns.Load(); n != 1 {
		t.Fatalf("sign-ins = %d, want 1", n)
	}
}

func TestSignInErrors(t *testing.T) {
	t.Run("signer down", func(t *testing.T) {
		_, srv := newFakeAPI(t)
		s := &stubSigner{err: fmt.Errorf("%w: no socket", model.ErrCZSignerUnavailable)}
		if _, err := newClient(srv, s, newClock()).Token(context.Background()); !errors.Is(err, model.ErrCZSignerUnavailable) {
			t.Fatalf("err = %v", err)
		}
	})
	t.Run("sign-in rejected", func(t *testing.T) {
		api, srv := newFakeAPI(t)
		api.signInErr = http.StatusForbidden
		_, err := newClient(srv, &stubSigner{}, newClock()).Token(context.Background())
		if !errors.Is(err, model.ErrCZAuthFailed) || !strings.Contains(err.Error(), "МЧД") {
			t.Fatalf("err = %v, want ErrCZAuthFailed with reason", err)
		}
	})
	t.Run("api down", func(t *testing.T) {
		api, srv := newFakeAPI(t)
		api.signInErr = http.StatusBadGateway
		if _, err := newClient(srv, &stubSigner{}, newClock()).Token(context.Background()); !errors.Is(err, model.ErrCZUnavailable) {
			t.Fatalf("err = %v", err)
		}
	})
}

func TestTokenWithoutExpUsesFallback(t *testing.T) {
	if _, ok := tokenExpiry(fakeJWT(`{"inn":"6234203222"}`)); ok {
		t.Fatal("exp found in token without exp")
	}
	if _, ok := tokenExpiry("not-a-jwt"); ok {
		t.Fatal("exp found in garbage")
	}
}

// cisesInfoBody — ответ cises/info по образцу CZ-01: марка, транспортный короб и отказ по коду.
const cisesInfoBody = `[
 {"cisInfo":{"requestedCis":"0104600000000017215abc","cis":"0104600000000017215abc",
   "gtin":"04600000000017","productName":"Лимонад","productGroup":"softdrinks",
   "packageType":"UNIT","status":"INTRODUCED","ownerInn":"6234203222","ownerName":"ООО Крафт",
   "producedDate":"2026-10-13T00:00:00.000Z","expirationDate":"2027-04-13T00:00:00.000Z",
   "parent":"0104600000000024215grp","tnVedEaes":"2202"}},
 {"cisInfo":{"requestedCis":"00146000000000000017","cis":"00146000000000000017",
   "packageType":"BOX","status":"INTRODUCED","child":["0104600000000017215abc","0104600000000017215abd"]}},
 {"cisInfo":{"requestedCis":"010460000000001721zzz"},"errorMessage":"Код не найден"}
]`

func TestCisesInfo(t *testing.T) {
	api, srv := newFakeAPI(t)
	api.infoBody = cisesInfoBody
	c := newClient(srv, &stubSigner{}, newClock())

	codes := []string{"0104600000000017215abc", "00146000000000000017", "010460000000001721zzz"}
	got, err := c.CisesInfo(context.Background(), codes)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(api.lastCodes, ",") != strings.Join(codes, ",") {
		t.Fatalf("sent codes = %v", api.lastCodes)
	}
	if len(got) != 3 {
		t.Fatalf("len = %d", len(got))
	}
	unit, box, missing := got[0], got[1], got[2]
	if unit.PackageType != "UNIT" || unit.ProducedDate != "2026-10-13T00:00:00.000Z" ||
		unit.Parent != "0104600000000024215grp" || unit.OwnerInn != "6234203222" {
		t.Fatalf("unit = %+v", unit)
	}
	// Поля, которых модель не знает, сохраняются в Raw.
	if !strings.Contains(string(unit.Raw), `"tnVedEaes":"2202"`) {
		t.Fatalf("raw lost fields: %s", unit.Raw)
	}
	if box.PackageType != "BOX" || len(box.Child) != 2 {
		t.Fatalf("box = %+v", box)
	}
	if missing.ErrorMessage != "Код не найден" || missing.RequestedCis != "010460000000001721zzz" {
		t.Fatalf("missing = %+v", missing)
	}
}

func TestCisesInfoRetriesOnceOn401(t *testing.T) {
	api, srv := newFakeAPI(t)
	api.infoBody = `[]`
	c := newClient(srv, &stubSigner{}, newClock())
	ctx := context.Background()
	if _, err := c.Token(ctx); err != nil {
		t.Fatal(err)
	}

	// ЧЗ отозвал токен раньше срока: клиент входит заново и повторяет запрос.
	api.mu.Lock()
	api.tokens = map[string]int{}
	api.mu.Unlock()
	if _, err := c.CisesInfo(ctx, []string{"x"}); err != nil {
		t.Fatal(err)
	}
	if n := api.signIns.Load(); n != 2 {
		t.Fatalf("sign-ins = %d, want 2", n)
	}

	// 401 и на новом токене — второй раз не повторяем.
	api.infoCode = func() int { return http.StatusUnauthorized }
	_, err := c.CisesInfo(ctx, []string{"x"})
	var se *statusError
	if !errors.As(err, &se) || se.code != http.StatusUnauthorized || api.signIns.Load() != 3 {
		t.Fatalf("err = %v, sign-ins = %d", err, api.signIns.Load())
	}
}

func TestCisesInfoErrors(t *testing.T) {
	cases := []struct {
		code int
		want error
	}{
		{http.StatusForbidden, model.ErrCZNoContract},
		{http.StatusNotFound, model.ErrCZNotFound},
		{http.StatusServiceUnavailable, model.ErrCZUnavailable},
	}
	for _, tc := range cases {
		t.Run(http.StatusText(tc.code), func(t *testing.T) {
			api, srv := newFakeAPI(t)
			api.infoCode = func() int { return tc.code }
			_, err := newClient(srv, &stubSigner{}, newClock()).CisesInfo(context.Background(), []string{"x"})
			if !errors.Is(err, tc.want) {
				t.Fatalf("err = %v, want %v", err, tc.want)
			}
		})
	}
}

func TestNextRefresh(t *testing.T) {
	exp := t0.Add(10 * time.Hour)
	cases := []struct {
		name     string
		now      time.Time
		failures int
		want     time.Duration
	}{
		{"fresh token", t0, 0, 9 * time.Hour},
		{"short token", exp.Add(-30 * time.Minute), 0, retryMin},
		{"1st failure", t0, 1, time.Minute},
		{"3rd failure", t0, 3, 4 * time.Minute},
		{"many failures", t0, 20, retryMax},
	}
	for _, tc := range cases {
		if got := nextRefresh(tc.now, exp, time.Hour, tc.failures); got != tc.want {
			t.Errorf("%s: got %v, want %v", tc.name, got, tc.want)
		}
	}
}

func TestRunObtainsTokenAndStops(t *testing.T) {
	api, srv := newFakeAPI(t)
	c := newClient(srv, &stubSigner{}, newClock())
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { c.Run(ctx); close(done) }()

	deadline := time.After(5 * time.Second)
	for api.signIns.Load() == 0 {
		select {
		case <-deadline:
			t.Fatal("no token obtained on start")
		case <-time.After(10 * time.Millisecond):
		}
	}
	cancel()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("Run did not stop on cancel")
	}
}

// TestSocketSigner — клиент подписанта против настоящего обработчика cz-signer на сокете.
func TestSocketSigner(t *testing.T) {
	dir, err := os.MkdirTemp("/tmp", "czt")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	ctx := context.Background()

	serve := func(name string, s czsigner.Signer) *SocketSigner {
		sock := filepath.Join(dir, name)
		ln, err := czsigner.ListenUnix(sock)
		if err != nil {
			t.Fatal(err)
		}
		srv := &http.Server{Handler: czsigner.NewHandler(quietLog, s)}
		go func() { _ = srv.Serve(ln) }()
		t.Cleanup(func() { _ = srv.Close() })
		return NewSocketSigner(sock)
	}

	ok := serve("ok.sock", &stubSigner{})
	if sig, err := ok.Sign(ctx, []byte("CHALLENGE")); err != nil || string(sig) != "SIG:CHALLENGE" {
		t.Fatalf("sign = %q, %v", sig, err)
	}
	if err := ok.Health(ctx); err != nil {
		t.Fatal(err)
	}

	broken := serve("broken.sock", &stubSigner{err: czsigner.ErrSign})
	if _, err := broken.Sign(ctx, []byte("x")); !errors.Is(err, model.ErrCZSignerUnavailable) {
		t.Fatalf("err = %v", err)
	}
	if err := broken.Health(ctx); !errors.Is(err, model.ErrCZSignerUnavailable) {
		t.Fatalf("health err = %v", err)
	}

	// Службы нет вовсе — та же ошибка, а не зависание.
	none := NewSocketSigner(filepath.Join(dir, "none.sock"))
	if _, err := none.Sign(ctx, []byte("x")); !errors.Is(err, model.ErrCZSignerUnavailable) {
		t.Fatalf("err = %v", err)
	}
}
