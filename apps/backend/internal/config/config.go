// Package config — загрузка конфигурации сервиса из переменных окружения.
//
// Зачем: один и тот же бинарь работает в dev/prod — различается только окружение
// (те же значения, что лежат в .env из P0-01). Хардкода настроек в коде нет.
package config

import (
	"log/slog"
	"os"
	"strings"
	"time"
)

// Config — набор настроек сервиса, считывается один раз при старте.
type Config struct {
	AppPort     string     // порт HTTP-сервера (env APP_PORT)
	LogLevel    slog.Level // уровень логирования (env LOG_LEVEL: debug|info|warn|error)
	DatabaseURL string     // DSN подключения к Postgres (env DATABASE_URL); пусто → сервис стартует без БД

	// Auth (P0-04)
	JWTSecret  string        // секрет подписи JWT (env JWT_SECRET); пусто → эфемерный секрет на время процесса
	AccessTTL  time.Duration // время жизни access-токена (env ACCESS_TTL), дефолт 12h
	RefreshTTL time.Duration // время жизни refresh-токена (env REFRESH_TTL), дефолт 720h (30 дней)

	// Отправка ошибок в Bugsink (ADHOC-42); SentryDSN пуст — отправка выключена.
	SentryDSN         string // адрес проекта Bugsink (env SENTRY_DSN)
	SentryEnvironment string // окружение событий (env SENTRY_ENVIRONMENT), дефолт prod
	SentryRelease     string // версия сборки (env SENTRY_RELEASE); пусто — без версии

	// Честный знак (CZ-02); CZSignerSocket пуст — чтение ЧЗ выключено.
	CZSignerSocket  string        // сокет подписанта cz-signer (env CZ_SIGNER_SOCKET)
	CZAPIURL        string        // адрес True API (env CZ_API_URL), дефолт — боевой
	CZRefreshBefore time.Duration // за сколько до истечения обновлять токен (env CZ_TOKEN_REFRESH_BEFORE), дефолт 1h
	CZOwnerINN      string        // ИНН нашей организации в ЧЗ (env CZ_OWNER_INN); пусто — владельца марки не сверяем
}

// Load читает конфиг из окружения, подставляя безопасные значения по умолчанию.
// Как: каждое поле — отдельная переменная env; отсутствие переменной не роняет старт,
// а даёт разумный дефолт (удобно для локального запуска вне docker).
func Load() Config {
	return Config{
		AppPort:     getEnv("APP_PORT", "8080"),
		LogLevel:    parseLevel(getEnv("LOG_LEVEL", "info")),
		DatabaseURL: getEnv("DATABASE_URL", ""),
		JWTSecret:   getEnv("JWT_SECRET", ""),
		AccessTTL:   parseDuration(getEnv("ACCESS_TTL", "12h"), 12*time.Hour),
		RefreshTTL:  parseDuration(getEnv("REFRESH_TTL", "720h"), 720*time.Hour),

		SentryDSN:         getEnv("SENTRY_DSN", ""),
		SentryEnvironment: getEnv("SENTRY_ENVIRONMENT", "prod"),
		SentryRelease:     getEnv("SENTRY_RELEASE", ""),

		CZSignerSocket:  getEnv("CZ_SIGNER_SOCKET", ""),
		CZAPIURL:        getEnv("CZ_API_URL", "https://markirovka.crpt.ru/api/v3/true-api"),
		CZRefreshBefore: parseDuration(getEnv("CZ_TOKEN_REFRESH_BEFORE", "1h"), time.Hour),
		CZOwnerINN:      strings.TrimSpace(getEnv("CZ_OWNER_INN", "")),
	}
}

// parseDuration разбирает строку длительности (напр. "12h", "720h"); при ошибке — дефолт.
func parseDuration(s string, def time.Duration) time.Duration {
	d, err := time.ParseDuration(strings.TrimSpace(s))
	if err != nil {
		return def
	}
	return d
}

// getEnv возвращает значение переменной окружения или дефолт, если она пуста/не задана.
func getEnv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// parseLevel переводит строковый уровень из env в slog.Level; неизвестное значение → info.
func parseLevel(s string) slog.Level {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "debug":
		return slog.LevelDebug
	case "warn", "warning":
		return slog.LevelWarn
	case "error":
		return slog.LevelError
	default:
		return slog.LevelInfo
	}
}
