package trueapi

import (
	"context"
	"time"
)

// Паузы фонового обновления после неудачи: растут вдвое от минимальной до максимальной, чтобы
// упавший подписант не долбили каждую минуту часами, но и не ждали до вечера после починки.
const (
	retryMin = time.Minute
	retryMax = 15 * time.Minute
)

// Run - фоновое обновление токена до отмены ctx.
//
// Как: получить токен сразу при старте, затем спать до порога обновления (за refreshBefore
// до истечения) и обновлять снова. Неудача пишется в журнал ошибкой - она уходит в Bugsink,
// и о сломанном подписанте узнают до того, как кладовщик отсканирует марку.
func (c *Client) Run(ctx context.Context) {
	failures := 0
	for {
		_, err := c.Token(ctx)
		if ctx.Err() != nil {
			return
		}
		if err != nil {
			failures++
			c.log.Error("true api token refresh failed", "error", err, "failures", failures)
		} else {
			failures = 0
		}
		expiry, _ := c.TokenExpiry()
		wait := nextRefresh(c.now(), expiry, c.refreshBefore, failures)

		t := time.NewTimer(wait)
		select {
		case <-ctx.Done():
			t.Stop()
			return
		case <-t.C:
		}
	}
}

// nextRefresh - сколько ждать до следующей попытки.
//
// После неудачи - пауза retryMin·2^(n-1), не больше retryMax. После успеха - до порога
// обновления, но не меньше retryMin: если ЧЗ выдал токен короче refreshBefore, цикл не должен
// крутиться вхолостую.
func nextRefresh(now, expiry time.Time, refreshBefore time.Duration, failures int) time.Duration {
	if failures > 0 {
		wait := retryMin
		for i := 1; i < failures && wait < retryMax; i++ {
			wait *= 2
		}
		return min(wait, retryMax)
	}
	return max(expiry.Add(-refreshBefore).Sub(now), retryMin)
}
