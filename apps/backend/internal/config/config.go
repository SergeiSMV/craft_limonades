// Package config — загрузка конфигурации сервиса из переменных окружения.
//
// Зачем: один и тот же бинарь работает в dev/prod — различается только окружение
// (те же значения, что лежат в .env из P0-01). Хардкода настроек в коде нет.
package config

import (
	"log/slog"
	"os"
	"strings"
)

// Config — набор настроек сервиса, считывается один раз при старте.
type Config struct {
	AppPort     string     // порт HTTP-сервера (env APP_PORT)
	LogLevel    slog.Level // уровень логирования (env LOG_LEVEL: debug|info|warn|error)
	DatabaseURL string     // DSN подключения к Postgres (env DATABASE_URL); пусто → сервис стартует без БД
}

// Load читает конфиг из окружения, подставляя безопасные значения по умолчанию.
// Как: каждое поле — отдельная переменная env; отсутствие переменной не роняет старт,
// а даёт разумный дефолт (удобно для локального запуска вне docker).
func Load() Config {
	return Config{
		AppPort:     getEnv("APP_PORT", "8080"),
		LogLevel:    parseLevel(getEnv("LOG_LEVEL", "info")),
		DatabaseURL: getEnv("DATABASE_URL", ""),
	}
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
