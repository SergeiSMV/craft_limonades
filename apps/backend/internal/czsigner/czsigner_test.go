package czsigner

import (
	"bytes"
	"context"
	"errors"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// Тесты CZ-02, шаг 1: подписант с подставным cryptcp - КриптоПро на машине разработчика нет.

// fakeCryptcp пишет в каталог теста shell-скрипт вместо cryptcp. Скрипт запоминает свои
// аргументы в args.txt, а «подписью» кладёт префикс SIG: + входные данные в последний аргумент.
// body - тело скрипта до подписи: им тесты задают отказ или зависание.
func fakeCryptcp(t *testing.T, body string) (path, argsFile string) {
	t.Helper()
	dir := t.TempDir()
	argsFile = filepath.Join(dir, "args.txt")
	script := `#!/bin/sh
printf '%s\n' "$@" > "` + argsFile + `"
` + body + `
for a in "$@"; do in="$out"; out="$a"; done
{ printf 'SIG:'; cat "$in"; } > "$out"
`
	path = filepath.Join(dir, "cryptcp")
	if err := os.WriteFile(path, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	return path, argsFile
}

func TestCryptcpSign(t *testing.T) {
	path, argsFile := fakeCryptcp(t, "")
	c := &Cryptcp{Path: path, Thumbprint: "70e8", PIN: "secret", Timeout: 5 * time.Second}

	sig, err := c.Sign(context.Background(), []byte("auth-key-data"))
	if err != nil {
		t.Fatal(err)
	}
	if string(sig) != "SIG:auth-key-data" {
		t.Fatalf("signature = %q", sig)
	}

	// Аргументы - как в разведке CZ-01, плюс пароль; входной и выходной файлы - последними.
	raw, _ := os.ReadFile(argsFile)
	args := strings.Fields(string(raw))
	want := []string{"-sign", "-uMy", "-thumbprint", "70e8", "-nochain", "-cadesbes", "-attached", "-der", "-pin", "secret"}
	if len(args) != len(want)+2 || strings.Join(args[:len(want)], " ") != strings.Join(want, " ") {
		t.Fatalf("args = %v", args)
	}
	// Временный каталог с данными удалён сразу после подписи.
	if _, err := os.Stat(filepath.Dir(args[len(args)-1])); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("temp dir not removed: %v", err)
	}
}

func TestCryptcpSignWithoutPIN(t *testing.T) {
	path, argsFile := fakeCryptcp(t, "")
	c := &Cryptcp{Path: path, Thumbprint: "70e8", Timeout: 5 * time.Second}
	if _, err := c.Sign(context.Background(), []byte("x")); err != nil {
		t.Fatal(err)
	}
	raw, _ := os.ReadFile(argsFile)
	if strings.Contains(string(raw), "-pin") {
		t.Fatalf("-pin passed without PIN: %s", raw)
	}
}

func TestCryptcpSignFailures(t *testing.T) {
	cases := []struct {
		name, body string
		timeout    time.Duration
		want       string
	}{
		{"cryptcp error", `echo "ErrorCode: 0x8010006b" ; exit 1`, 5 * time.Second, "0x8010006b"},
		{"no signature", `exit 0`, 5 * time.Second, "no signature"},
		{"timeout", `sleep 5`, 200 * time.Millisecond, "timeout"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			path, _ := fakeCryptcp(t, tc.body)
			c := &Cryptcp{Path: path, Thumbprint: "70e8", Timeout: tc.timeout}
			_, err := c.Sign(context.Background(), []byte("x"))
			if !errors.Is(err, ErrSign) || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("err = %v, want ErrSign with %q", err, tc.want)
			}
		})
	}
}

// stubSigner - подпись без cryptcp для тестов обработчика.
type stubSigner struct{ err error }

func (s stubSigner) Sign(_ context.Context, data []byte) ([]byte, error) {
	if s.err != nil {
		return nil, s.err
	}
	return append([]byte("SIG:"), data...), nil
}

// serveSocket поднимает обработчик на unix-сокете во временном каталоге и отдаёт клиента к нему.
func serveSocket(t *testing.T, s Signer) *http.Client {
	t.Helper()
	// Короткий путь: у unix-сокета предел длины ~104 байта, а t.TempDir() на macOS длинный.
	dir, err := os.MkdirTemp("/tmp", "czs")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	sock := filepath.Join(dir, "s.sock")
	ln, err := ListenUnix(sock)
	if err != nil {
		t.Fatal(err)
	}
	fi, _ := os.Stat(sock)
	if fi.Mode().Perm() != SocketMode {
		t.Fatalf("socket mode = %v", fi.Mode().Perm())
	}
	srv := &http.Server{Handler: NewHandler(slog.New(slog.NewTextHandler(io.Discard, nil)), s)}
	go func() { _ = srv.Serve(ln) }()
	t.Cleanup(func() { _ = srv.Close() })
	return &http.Client{Transport: &http.Transport{
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, "unix", sock)
		},
	}}
}

func TestHandler(t *testing.T) {
	ok := serveSocket(t, stubSigner{})
	broken := serveSocket(t, stubSigner{err: ErrSign})

	cases := []struct {
		name     string
		client   *http.Client
		method   string
		path     string
		body     []byte
		code     int
		wantBody string
	}{
		{"sign", ok, http.MethodPost, "/sign", []byte("data"), 200, "SIG:data"},
		{"empty body", ok, http.MethodPost, "/sign", nil, 400, "empty body"},
		{"too large", ok, http.MethodPost, "/sign", bytes.Repeat([]byte("x"), maxDataSize+1), 400, "too large"},
		{"sign failed", broken, http.MethodPost, "/sign", []byte("data"), 503, "signing failed"},
		{"health", ok, http.MethodGet, "/health", nil, 200, `"ok"`},
		{"health failed", broken, http.MethodGet, "/health", nil, 503, "signing failed"},
		{"wrong method", ok, http.MethodGet, "/sign", nil, 405, ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			req, _ := http.NewRequest(tc.method, "http://signer"+tc.path, bytes.NewReader(tc.body))
			resp, err := tc.client.Do(req)
			if err != nil {
				t.Fatal(err)
			}
			defer func() { _ = resp.Body.Close() }()
			body, _ := io.ReadAll(resp.Body)
			if resp.StatusCode != tc.code || !strings.Contains(string(body), tc.wantBody) {
				t.Fatalf("got %d %q, want %d with %q", resp.StatusCode, body, tc.code, tc.wantBody)
			}
		})
	}
}

func TestListenUnixStaleSocket(t *testing.T) {
	dir, _ := os.MkdirTemp("/tmp", "czs")
	defer func() { _ = os.RemoveAll(dir) }()
	sock := filepath.Join(dir, "s.sock")

	// Сокет от «упавшего» прошлого запуска: файл остался, слушателя нет.
	ln, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	ln.(*net.UnixListener).SetUnlinkOnClose(false)
	_ = ln.Close()

	ln2, err := ListenUnix(sock)
	if err != nil {
		t.Fatalf("stale socket not replaced: %v", err)
	}
	_ = ln2.Close()

	// Обычный файл на месте сокета - не трогаем.
	plain := filepath.Join(dir, "plain")
	_ = os.WriteFile(plain, []byte("x"), 0o600)
	if _, err := ListenUnix(plain); err == nil {
		t.Fatal("regular file replaced by socket")
	}
	if _, err := os.Stat(plain); err != nil {
		t.Fatal("regular file removed")
	}
}
