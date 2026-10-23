package czsigner

import (
	"errors"
	"fmt"
	"io/fs"
	"net"
	"os"
)

// SocketMode — права на сокет: владелец (служба) и группа (бэкенд через group_add).
// Остальным пользователям сервера подписывать нельзя.
const SocketMode fs.FileMode = 0o660

// ListenUnix открывает unix-сокет подписанта по пути path с правами SocketMode.
//
// Как: сокет, оставшийся от прошлого запуска (служба упала, не убрав его), удаляется —
// иначе Listen падает с «address already in use». Удаляется только сокет: если по пути
// лежит обычный файл, это ошибка конфигурации, и трогать его нельзя.
func ListenUnix(path string) (net.Listener, error) {
	if fi, err := os.Lstat(path); err == nil {
		if fi.Mode().Type() != fs.ModeSocket {
			return nil, fmt.Errorf("%s exists and is not a socket", path)
		}
		if err := os.Remove(path); err != nil {
			return nil, fmt.Errorf("remove stale socket: %w", err)
		}
	} else if !errors.Is(err, fs.ErrNotExist) {
		return nil, err
	}

	ln, err := net.Listen("unix", path)
	if err != nil {
		return nil, err
	}
	if err := os.Chmod(path, SocketMode); err != nil {
		_ = ln.Close()
		return nil, fmt.Errorf("chmod socket: %w", err)
	}
	return ln, nil
}
