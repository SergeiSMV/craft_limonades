// Package czsigner — подписант Честного знака (CZ-02): подпись байтов КЭП через КриптоПро.
//
// Зачем: True API выдаёт токен в обмен на строку auth/key, подписанную КЭП. Ключ и КриптоПро
// живут на хосте, а не в контейнере бэкенда, поэтому подпись вынесена в отдельную службу,
// которая умеет ровно одно — подписать присланные байты. Про True API она ничего не знает.
package czsigner

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// ErrSign — подписать не удалось: нет ключа или сертификата, неверный пароль, cryptcp упал
// или не уложился в таймаут. Подробность — в обёрнутом тексте, для журнала.
var ErrSign = errors.New("signing failed")

// Cryptcp — подпись утилитой КриптоПро cryptcp: присоединённая CAdES-BES в DER.
//
// Как: на каждый вызов — временный каталог 700 с входным файлом, cryptcp пишет рядом подпись,
// каталог удаляется сразу. Вызовы идут по одному (mutex): ключ один, а параллельный доступ
// к контейнеру КриптоПро ничего не ускоряет и рискует блокировками. Ввод у cryptcp закрыт —
// если он вдруг что-то спросит, вызов упадёт, а не повиснет.
type Cryptcp struct {
	Path       string        // путь к cryptcp
	Thumbprint string        // SHA1-отпечаток сертификата подписанта в хранилище uMy
	PIN        string        // пароль контейнера ключа; пусто — без пароля
	Timeout    time.Duration // предел на один вызов

	mu sync.Mutex
}

// Sign подписывает data и возвращает подпись (DER, данные внутри подписи).
func (c *Cryptcp) Sign(ctx context.Context, data []byte) ([]byte, error) {
	if len(data) == 0 {
		return nil, fmt.Errorf("%w: empty data", ErrSign)
	}
	c.mu.Lock()
	defer c.mu.Unlock()

	dir, err := os.MkdirTemp("", "cz-sign-")
	if err != nil {
		return nil, fmt.Errorf("%w: temp dir: %v", ErrSign, err)
	}
	defer func() { _ = os.RemoveAll(dir) }()
	in, out := filepath.Join(dir, "data"), filepath.Join(dir, "data.sig")
	if err := os.WriteFile(in, data, 0o600); err != nil {
		return nil, fmt.Errorf("%w: write data: %v", ErrSign, err)
	}

	ctx, cancel := context.WithTimeout(ctx, c.Timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, c.Path, c.args(in, out)...)
	var stderr bytes.Buffer
	cmd.Stdout = &stderr // cryptcp пишет диагностику в stdout — собираем вместе со stderr
	cmd.Stderr = &stderr
	// По таймауту убивается сам cryptcp; его потомки могут держать вывод открытым — не ждём их.
	cmd.WaitDelay = time.Second
	if err := cmd.Run(); err != nil {
		if ctx.Err() != nil {
			return nil, fmt.Errorf("%w: cryptcp timeout after %s", ErrSign, c.Timeout)
		}
		return nil, fmt.Errorf("%w: cryptcp: %v: %s", ErrSign, err, tail(stderr.String()))
	}

	sig, err := os.ReadFile(out)
	if err != nil || len(sig) == 0 {
		return nil, fmt.Errorf("%w: cryptcp produced no signature: %s", ErrSign, tail(stderr.String()))
	}
	return sig, nil
}

// args — аргументы cryptcp, те же, что в разведке CZ-01 (scripts/cz-probe/token.sh), но с
// паролем аргументом вместо вопроса: -nochain — цепочку не проверяем (её проверяет ЧЗ),
// -attached — данные внутри подписи, как ждёт simpleSignIn.
func (c *Cryptcp) args(in, out string) []string {
	a := []string{"-sign", "-uMy", "-thumbprint", c.Thumbprint, "-nochain", "-cadesbes", "-attached", "-der"}
	if c.PIN != "" {
		a = append(a, "-pin", c.PIN)
	}
	return append(a, in, out)
}

// tail — последние строки вывода cryptcp для журнала: он многословен, суть ошибки — в конце.
func tail(s string) string {
	s = strings.TrimSpace(s)
	const max = 500
	if len(s) > max {
		s = "…" + s[len(s)-max:]
	}
	return s
}
