// Package main — подписант Честного знака (CZ-02): служба на хосте, подписывает байты КЭП.
//
// Зачем: КриптоПро CSP, ключ и сертификат стоят на сервере, а не в контейнере бэкенда. Бэкенд
// присылает сюда строку auth/key True API и получает подпись, по которой ЧЗ выдаёт токен.
// Как: HTTP поверх unix-сокета (в сеть не выходит), подпись — утилитой cryptcp. Запускается
// systemd-юнитом craft-wms-cz-signer.service от пользователя, у которого лежит ключ; бинарь
// едет в образе бэкенда, update.sh достаёт его на хост.
//
// Окружение:
//
//	CZ_SIGNER_THUMB   — SHA1-отпечаток сертификата в uMy (обязателен);
//	CZ_SIGNER_PIN     — пароль контейнера ключа (пусто — без пароля);
//	CZ_SIGNER_SOCKET  — путь сокета, по умолчанию /run/cz-signer/sign.sock;
//	CZ_SIGNER_CRYPTCP — путь к cryptcp, по умолчанию /opt/cprocsp/bin/amd64/cryptcp;
//	CZ_SIGNER_TIMEOUT — предел на одну подпись, по умолчанию 30s.
package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"craftwms/internal/czsigner"
)

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stdout, nil))

	// 1. Настройки. Без отпечатка подписывать нечем — падаем сразу, systemd покажет причину.
	thumb := strings.ToLower(strings.ReplaceAll(os.Getenv("CZ_SIGNER_THUMB"), " ", ""))
	if thumb == "" {
		log.Error("CZ_SIGNER_THUMB is required")
		os.Exit(1)
	}
	timeout, err := time.ParseDuration(getEnv("CZ_SIGNER_TIMEOUT", "30s"))
	if err != nil || timeout <= 0 {
		log.Error("bad CZ_SIGNER_TIMEOUT", "value", os.Getenv("CZ_SIGNER_TIMEOUT"))
		os.Exit(1)
	}
	signer := &czsigner.Cryptcp{
		Path:       getEnv("CZ_SIGNER_CRYPTCP", "/opt/cprocsp/bin/amd64/cryptcp"),
		Thumbprint: thumb,
		PIN:        os.Getenv("CZ_SIGNER_PIN"),
		Timeout:    timeout,
	}
	if _, err := os.Stat(signer.Path); err != nil {
		log.Error("cryptcp not found", "path", signer.Path, "error", err)
		os.Exit(1)
	}

	// 2. Сокет. Каталог создаёт systemd (RuntimeDirectory), группу задаёт юнит.
	socket := getEnv("CZ_SIGNER_SOCKET", "/run/cz-signer/sign.sock")
	ln, err := czsigner.ListenUnix(socket)
	if err != nil {
		log.Error("cannot listen", "socket", socket, "error", err)
		os.Exit(1)
	}

	// 3. Сервер; таймауты чтения — на случай зависшего клиента, запись ждёт cryptcp.
	srv := &http.Server{
		Handler:           czsigner.NewHandler(log, signer),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      timeout + 10*time.Second,
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), timeout)
		defer cancel()
		_ = srv.Shutdown(shutdownCtx)
	}()

	log.Info("cz-signer started", "socket", socket)
	if err := srv.Serve(ln); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Error("serve failed", "error", err)
		os.Exit(1)
	}
	// Shutdown закрыл слушатель — net сам удаляет файл unix-сокета.
	log.Info("cz-signer stopped")
}

// getEnv — значение переменной окружения или дефолт, если она пуста.
func getEnv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
