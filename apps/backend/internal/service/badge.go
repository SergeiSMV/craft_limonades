package service

import (
	"context"

	"craftwms/internal/auth"
	"craftwms/internal/model"
)

// badgeRepo — что сервису бейджей нужно от хранилища (ADHOC-65).
type badgeRepo interface {
	Holders(ctx context.Context) ([]model.BadgeHolder, error)
	Holder(ctx context.Context, id string) (model.BadgeHolder, error)
	LogPrint(ctx context.Context, by, id string) error
}

// accessRepo — права пользователя на момент запроса.
type accessRepo interface {
	UserAccess(ctx context.Context, userID string) (model.Access, error)
}

// BadgeService — печать бейджей сотрудников на ТСД (ADHOC-65).
//
// Что: список сотрудников, чьи бейджи пользователь вправе печатать, и номер бейджа к печати.
// Уровень — самый широкий из прав «Бейджи»: свой; всех, кроме администратора; всех. Номер
// хранится зашифрованным и раскрывается только здесь, каждое раскрытие — в audit_log: бейдж
// — это вход в систему от имени сотрудника.
type BadgeService struct {
	repo   badgeRepo
	access accessRepo
	cipher *auth.BadgeCipher // nil — ключ не задан, номера не раскрываются
}

// NewBadgeService создаёт сервис бейджей; cipher nil — печать отвечает «не настроена».
func NewBadgeService(repo badgeRepo, access accessRepo, cipher *auth.BadgeCipher) *BadgeService {
	return &BadgeService{repo: repo, access: access, cipher: cipher}
}

// Holders — сотрудники, чьи бейджи пользователь [by] вправе печатать, с отметкой «номер есть».
func (s *BadgeService) Holders(ctx context.Context, by string) ([]model.BadgeListItem, error) {
	scope, err := s.scope(ctx, by)
	if err != nil {
		return nil, err
	}
	all, err := s.repo.Holders(ctx)
	if err != nil {
		return nil, err
	}
	out := make([]model.BadgeListItem, 0, len(all))
	for _, h := range all {
		if !scope.Allows(h.ID == by, h.IsAdmin) {
			continue
		}
		_, openErr := s.number(h)
		out = append(out, model.BadgeListItem{
			ID: h.ID, FullName: h.FullName, PositionName: h.PositionName, IsAdmin: h.IsAdmin,
			Stored: openErr == nil,
		})
	}
	return out, nil
}

// Badge — номер бейджа сотрудника [id] к печати; раскрытие пишется в audit_log.
func (s *BadgeService) Badge(ctx context.Context, by, id string) (model.Badge, error) {
	if !isUUID(id) {
		return model.Badge{}, model.ErrUserMissing
	}
	scope, err := s.scope(ctx, by)
	if err != nil {
		return model.Badge{}, err
	}
	h, err := s.repo.Holder(ctx, id)
	if err != nil {
		return model.Badge{}, err
	}
	if !scope.Allows(h.ID == by, h.IsAdmin) {
		return model.Badge{}, model.ErrBadgeForbidden
	}
	if s.cipher == nil {
		return model.Badge{}, model.ErrBadgeKeyMissing
	}
	number, err := s.number(h)
	if err != nil {
		return model.Badge{}, err
	}
	if err := s.repo.LogPrint(ctx, by, h.ID); err != nil {
		return model.Badge{}, err
	}
	return model.Badge{UserID: h.ID, FullName: h.FullName, Number: number}, nil
}

// scope — уровень печати пользователя; без прав «Бейджи» — ErrBadgeForbidden.
func (s *BadgeService) scope(ctx context.Context, by string) (model.BadgeScope, error) {
	a, err := s.access.UserAccess(ctx, by)
	if err != nil {
		return model.BadgeScopeNone, err
	}
	scope := model.BadgeScopeOf(a)
	if !a.Active || scope == model.BadgeScopeNone {
		return model.BadgeScopeNone, model.ErrBadgeForbidden
	}
	return scope, nil
}

// number — 16 цифр бейджа; номера нет, ключа нет или он другой — ErrBadgeNotStored.
func (s *BadgeService) number(h model.BadgeHolder) (string, error) {
	if s.cipher == nil || h.Sealed == nil {
		return "", model.ErrBadgeNotStored
	}
	secret, err := s.cipher.Open(h.Login, h.Sealed)
	if err != nil || !isBadge(h.Login+secret) {
		return "", model.ErrBadgeNotStored
	}
	return h.Login + secret, nil
}
