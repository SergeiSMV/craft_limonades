package service

import (
	"context"
	"slices"
	"strings"
	"unicode/utf8"

	"craftwms/internal/auth"
	"craftwms/internal/model"
	"craftwms/internal/repository"
)

// userAdminRepo - что сервису пользователей нужно от хранилища (ADHOC-49).
type userAdminRepo interface {
	Positions(ctx context.Context) ([]model.Position, error)
	CreatePosition(ctx context.Context, in model.PositionInput, by string) (string, error)
	UpdatePosition(ctx context.Context, id string, in model.PositionInput, by string) error
	DeletePosition(ctx context.Context, id, by string) error
	Users(ctx context.Context) ([]model.UserListItem, error)
	CreateUser(ctx context.Context, u repository.NewUser) (string, error)
	UpdateUser(ctx context.Context, c repository.UserChange) error
	IsBadgeUser(ctx context.Context, id string) (bool, error)
}

// UserAdminService - пользователи и должности в портале (ADHOC-49): форма ввода, способ
// входа и хеш секрета. Последнего администратора и системную должность бережёт репозиторий -
// в той же транзакции, что и правку.
type UserAdminService struct {
	repo userAdminRepo
	// badges - шифр номеров бейджей для печати (ADHOC-65); nil - номер не сохраняется.
	badges *auth.BadgeCipher
}

// NewUserAdminService создаёт сервис пользователей и должностей; badges - шифр номеров
// бейджей для печати на ТСД (nil - выданный номер не запоминается).
func NewUserAdminService(repo userAdminRepo, badges *auth.BadgeCipher) *UserAdminService {
	return &UserAdminService{repo: repo, badges: badges}
}

// sealBadge - зашифрованный секрет выданного бейджа для печати; без ключа - nil.
func (s *UserAdminService) sealBadge(badge string) ([]byte, error) {
	if s.badges == nil {
		return nil, nil
	}
	return s.badges.Seal(badge[:8], badge[8:])
}

// Ограничения ввода: название должности - как в схеме, пароль - не короче 8 символов.
const (
	positionNameMax = 64
	fullNameMax     = 200
	usernameMin     = 3
	usernameMax     = 64
	passwordMin     = 8
)

// Rights - все права в порядке показа.
func (s *UserAdminService) Rights() []string { return slices.Clone(model.Rights) }

// Positions - должности с действующими правами и числом пользователей.
func (s *UserAdminService) Positions(ctx context.Context) ([]model.Position, error) {
	return s.repo.Positions(ctx)
}

// CreatePosition заводит должность.
func (s *UserAdminService) CreatePosition(ctx context.Context, in model.PositionInput, by string) (string, error) {
	in, err := normalizePosition(in)
	if err != nil {
		return "", err
	}
	return s.repo.CreatePosition(ctx, in, by)
}

// UpdatePosition меняет название и права должности.
func (s *UserAdminService) UpdatePosition(ctx context.Context, id string, in model.PositionInput, by string) error {
	if !isUUID(id) {
		return model.ErrPositionNotFound
	}
	in, err := normalizePosition(in)
	if err != nil {
		return err
	}
	return s.repo.UpdatePosition(ctx, id, in, by)
}

// DeletePosition удаляет должность без пользователей.
func (s *UserAdminService) DeletePosition(ctx context.Context, id, by string) error {
	if !isUUID(id) {
		return model.ErrPositionNotFound
	}
	return s.repo.DeletePosition(ctx, id, by)
}

// Users - все пользователи, и заблокированные.
func (s *UserAdminService) Users(ctx context.Context) ([]model.UserListItem, error) {
	return s.repo.Users(ctx)
}

// CreateUser заводит пользователя: ровно один способ входа - бейдж (16 цифр: логин - первые
// 8, секрет - последние 8, как при входе) или логин с паролем.
func (s *UserAdminService) CreateUser(ctx context.Context, in model.UserCreateInput) (string, error) {
	name, ok := normalizeFullName(in.FullName)
	if !ok || !isUUID(in.PositionID) {
		return "", model.ErrInvalidUser
	}
	u := repository.NewUser{FullName: name, PositionID: in.PositionID, By: in.By}
	username := strings.TrimSpace(in.Username)
	switch {
	case in.Badge != "" && username == "" && in.Password == "":
		if !isBadge(in.Badge) {
			return "", model.ErrBadBadge
		}
		hash, err := auth.HashPassword(in.Badge[8:])
		if err != nil {
			return "", err
		}
		u.Login, u.PasswordHash = in.Badge[:8], hash
		if u.BadgeSecretEnc, err = s.sealBadge(in.Badge); err != nil {
			return "", err
		}
	case in.Badge == "" && validUsername(username) && validPassword(in.Password):
		hash, err := auth.HashPassword(in.Password)
		if err != nil {
			return "", err
		}
		u.Username, u.PasswordHash = username, hash
	default:
		return "", model.ErrInvalidUser
	}
	return s.repo.CreateUser(ctx, u)
}

// UpdateUser правит пользователя. Новый бейдж - только у входящего по бейджу, новый пароль -
// только у входящего по логину: способ входа не меняется. Себя заблокировать нельзя.
func (s *UserAdminService) UpdateUser(ctx context.Context, in model.UserUpdateInput) error {
	if !isUUID(in.ID) {
		return model.ErrUserMissing
	}
	c := repository.UserChange{ID: in.ID, IsActive: in.IsActive, By: in.By}
	if in.IsActive != nil && !*in.IsActive && in.ID == in.By {
		return model.ErrSelfBlock
	}
	if in.FullName != nil {
		name, ok := normalizeFullName(*in.FullName)
		if !ok {
			return model.ErrInvalidUser
		}
		c.FullName = &name
	}
	if in.PositionID != nil {
		if !isUUID(*in.PositionID) {
			return model.ErrPositionNotFound
		}
		c.PositionID = in.PositionID
	}
	if in.Badge != nil || in.Password != nil {
		badgeUser, err := s.repo.IsBadgeUser(ctx, in.ID)
		if err != nil {
			return err
		}
		switch {
		case in.Badge != nil && in.Password == nil && badgeUser:
			if !isBadge(*in.Badge) {
				return model.ErrBadBadge
			}
			hash, err := auth.HashPassword((*in.Badge)[8:])
			if err != nil {
				return err
			}
			login := (*in.Badge)[:8]
			c.Login, c.PasswordHash = &login, &hash
			// Новый бейдж заменяет и сохранённый номер: без ключа - пусто, а не прежний.
			if c.BadgeSecretEnc, err = s.sealBadge(*in.Badge); err != nil {
				return err
			}
		case in.Password != nil && in.Badge == nil && !badgeUser:
			if !validPassword(*in.Password) {
				return model.ErrInvalidUser
			}
			hash, err := auth.HashPassword(*in.Password)
			if err != nil {
				return err
			}
			c.PasswordHash = &hash
		default:
			return model.ErrInvalidUser
		}
	}
	return s.repo.UpdateUser(ctx, c)
}

// normalizePosition - название без крайних пробелов, права - известные, без повторов, в
// порядке показа.
func normalizePosition(in model.PositionInput) (model.PositionInput, error) {
	name := strings.TrimSpace(in.Name)
	if name == "" || utf8.RuneCountInString(name) > positionNameMax {
		return in, model.ErrInvalidPosition
	}
	for _, r := range in.Rights {
		if !slices.Contains(model.Rights, r) {
			return in, model.ErrInvalidPosition
		}
	}
	return model.PositionInput{Name: name, Rights: model.UserRights(false, in.Rights)}, nil
}

func normalizeFullName(s string) (string, bool) {
	s = strings.Join(strings.Fields(s), " ")
	return s, s != "" && utf8.RuneCountInString(s) <= fullNameMax
}

func validUsername(s string) bool {
	n := utf8.RuneCountInString(s)
	return n >= usernameMin && n <= usernameMax && !strings.ContainsAny(s, " \t")
}

func validPassword(s string) bool { return utf8.RuneCountInString(s) >= passwordMin }
