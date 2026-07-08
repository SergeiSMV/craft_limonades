// Package main — точка входа backend-сервиса Craft WMS.
//
// На этапе P0-01 это минимальный HTTP-сервер с единственным эндпоинтом /health.
// Его задача — дать docker-контейнеру «живой» процесс: на него навешивается
// healthcheck, и через него nginx проверяет доступность стека.
// Полноценный скелет (роутер chi, конфиг, логгер, graceful shutdown) добавляется
// в задаче P0-02 — тогда же этот файл разворачивается в слоистую структуру.
package main

import (
	"log"
	"net/http"
	"os"
)

func main() {
	// Порт берём из окружения — один и тот же код работает в dev/prod без правок.
	// Значение по умолчанию нужно на случай запуска вне docker (локальная отладка).
	port := os.Getenv("APP_PORT")
	if port == "" {
		port = "8080"
	}

	mux := http.NewServeMux()

	// /health — liveness-проба: отвечает 200 и JSON-статусом.
	// Используется healthcheck'ом контейнера и проверкой доступности через nginx.
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"status":"ok"}`))
	})

	addr := ":" + port
	log.Printf("backend listening on %s", addr)

	// P0-02 заменит это на http.Server с graceful shutdown по сигналам ОС.
	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Fatalf("server stopped: %v", err)
	}
}
