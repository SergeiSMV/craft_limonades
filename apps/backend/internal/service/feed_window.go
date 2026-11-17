package service

import (
	"errors"
	"strings"
	"time"
)

// errInvalidFeedWindow - период или курсор ленты не разобран. Сервисы лент отдают наружу
// свою ошибку фильтра, эта - внутренняя.
var errInvalidFeedWindow = errors.New("invalid feed window")

// feedWindow - период и курсор ленты («Завершённые» задания, история перемещений), разобранные
// из транспортного вида.
type feedWindow struct {
	From, To *time.Time // To не включается: день «по» уже прибавлен целиком
	Before   *time.Time // курсор: момент последней показанной записи
	BeforeID string     // и её id - момент у двух записей может совпасть
	Limit    int
}

// parseFeedWindow разбирает период и курсор ленты.
//
// Даты - 'YYYY-MM-DD' по времени склада (МСК): «день» в фильтре - день склада, а не UTC
// сервера; `to` включается целиком. Курсор - момент (RFC3339) и id последней записи, без id
// не принимается. Limit приводится к [1, max], ноль - значение по умолчанию.
func parseFeedWindow(from, to, before, beforeID string, limit, defLimit, maxLimit int) (feedWindow, error) {
	w := feedWindow{BeforeID: strings.TrimSpace(beforeID), Limit: limit}
	if w.Limit <= 0 {
		w.Limit = defLimit
	}
	if w.Limit > maxLimit {
		w.Limit = maxLimit
	}
	if !isOptionalUUID(w.BeforeID) {
		return feedWindow{}, errInvalidFeedWindow
	}
	if v := strings.TrimSpace(from); v != "" {
		d, err := time.ParseInLocation(time.DateOnly, v, warehouseZone)
		if err != nil {
			return feedWindow{}, errInvalidFeedWindow
		}
		w.From = &d
	}
	if v := strings.TrimSpace(to); v != "" {
		d, err := time.ParseInLocation(time.DateOnly, v, warehouseZone)
		if err != nil {
			return feedWindow{}, errInvalidFeedWindow
		}
		end := d.AddDate(0, 0, 1)
		w.To = &end
	}
	if v := strings.TrimSpace(before); v != "" {
		t, err := time.Parse(time.RFC3339Nano, v)
		if err != nil || w.BeforeID == "" {
			return feedWindow{}, errInvalidFeedWindow
		}
		w.Before = &t
	}
	return w, nil
}
