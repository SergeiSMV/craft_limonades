package model

import "errors"

// BadgeScope - чьи бейджи пользователь печатает на ТСД (ADHOC-65); уровни по возрастанию.
type BadgeScope int

// Уровни печати бейджей: никаких, свой, всех кроме администратора, всех.
const (
	BadgeScopeNone BadgeScope = iota
	BadgeScopeOwn
	BadgeScopeStaff
	BadgeScopeAll
)

// BadgeScopeOf - самый широкий уровень из прав доступа; «Администратор» - всех.
func BadgeScopeOf(a Access) BadgeScope {
	switch {
	case a.System || a.Can(RightTSDBadgesAll):
		return BadgeScopeAll
	case a.Can(RightTSDBadgesStaff):
		return BadgeScopeStaff
	case a.Can(RightTSDBadgesOwn):
		return BadgeScopeOwn
	default:
		return BadgeScopeNone
	}
}

// Allows - пускает ли уровень к бейджу пользователя [target] (self - свой бейдж, admin -
// системная должность «Администратор»).
func (s BadgeScope) Allows(self, admin bool) bool {
	switch s {
	case BadgeScopeAll:
		return true
	case BadgeScopeStaff:
		return self || !admin
	case BadgeScopeOwn:
		return self
	default:
		return false
	}
}

// BadgeHolder - сотрудник с бейджем, как его видит раздел «Бейджи» (ADHOC-65): активный, входит
// по бейджу. Sealed - зашифрованный секрет; номер наружу отдаёт только печать.
type BadgeHolder struct {
	ID           string
	FullName     string
	PositionName string
	IsAdmin      bool // системная должность «Администратор»
	Login        string
	Sealed       []byte
}

// BadgeListItem - строка списка «Бейджи» на ТСД: без номера, только можно ли напечатать.
type BadgeListItem struct {
	ID           string
	FullName     string
	PositionName string
	IsAdmin      bool
	Stored       bool // номер сохранён и расшифровывается - печать возможна
}

// Badge - номер бейджа к печати.
type Badge struct {
	UserID   string
	FullName string
	Number   string // 16 цифр
}

// Ошибки печати бейджей (ADHOC-65). Тексты - для экрана ТСД.
var (
	ErrBadgeForbidden  = errors.New("нет права печатать этот бейдж")
	ErrBadgeNotStored  = errors.New("номер бейджа не сохранён: сотрудник должен один раз войти по нему или получить новый бейдж в портале")
	ErrBadgeKeyMissing = errors.New("печать бейджей не настроена на сервере: не задан ключ BADGE_KEY")
)
