// Package main — точка входа backend-сервиса Craft WMS.
//
// P0-02: минимальный, но «правильный» каркас HTTP-сервиса — конфиг из окружения,
// структурированный логгер, chi-роутер и graceful shutdown. Бизнес-логики ещё нет:
// это «розетка», в которую дальше подключаются auth, справочники и операции.
package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"craftwms/internal/config"
	"craftwms/internal/handler"
)

// shutdownTimeout — сколько ждём завершения текущих запросов при мягкой остановке.
const shutdownTimeout = 10 * time.Second

func main() {
	// 1. Конфиг из окружения — один бинарь для dev/prod, меняется только окружение.
	cfg := config.Load()

	// 2. Общий структурированный JSON-логгер (пишет в stdout — стандарт для контейнеров).
	log := newLogger(cfg.LogLevel)
	slog.SetDefault(log)

	// 3. HTTP-сервер с собранным роутером транспортного слоя.
	srv := &http.Server{
		Addr:              ":" + cfg.AppPort,
		Handler:           handler.NewRouter(log),
		ReadHeaderTimeout: 5 * time.Second, // защита от медленных клиентов (Slowloris)
	}

	// 4. Контекст, отменяемый по SIGINT/SIGTERM — сигнал начать мягкую остановку
	//    (SIGTERM прилетает при `docker compose down` / редеплое).
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	// 5. Запускаем приём соединений в отдельной горутине, чтобы main мог ждать сигнал.
	go func() {
		log.Info("backend listening", "addr", srv.Addr, "log_level", cfg.LogLevel.String())
		// ErrServerClosed — штатное завершение после Shutdown, ошибкой не считаем.
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Error("server failed", "error", err)
			stop() // будим main для завершения процесса
		}
	}()

	// 6. Блокируемся до сигнала остановки.
	<-ctx.Done()
	log.Info("shutdown signal received, draining connections")

	// 7. Graceful shutdown: перестаём принимать новые соединения и даём текущим запросам
	//    до-обработаться в пределах таймаута. Зачем: не рвать операцию на полуслове —
	//    в WMS это критично для консистентности остатков.
	shutdownCtx, cancel := context.WithTimeout(context.Background(), shutdownTimeout)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		log.Error("graceful shutdown failed", "error", err)
		os.Exit(1)
	}
	log.Info("server stopped cleanly")
}

// newLogger собирает JSON-логгер slog с заданным уровнем.
func newLogger(level slog.Level) *slog.Logger {
	return slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: level}))
}
