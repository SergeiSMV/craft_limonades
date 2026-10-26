// Package model — сущности предметной области (чистые структуры без внешних зависимостей).
package model

import (
	"errors"
	"slices"
	"time"
)

// Роли пользователя — прежняя модель доступа (до ADHOC-49). Теперь роль не хранится, а
// выводится из прав должности: admin — у кого есть право «пользователи и должности». Её ещё
// читают старые сборки ТСД и портала (`/auth/me`) и метка события Bugsink.
const (
	RoleEmployee = "employee"
	RoleAdmin    = "admin"
)

// Права должности (ADHOC-49). Коды фиксированы — их проверяет код; список совпадает с
// ограничением positions.rights в миграции 33.
const (
	RightTSD        = "tsd"        // работа на ТСД
	RightPortal     = "portal"     // вход в портал
	RightCatalog    = "catalog"    // справочники: импорт номенклатуры и ячеек, этикетки
	RightDocuments  = "documents"  // документы для 1С: скачать и «Провести»
	RightProblems   = "problems"   // проблемы склада: решения офиса
	RightStocktake  = "stocktake"  // пересчёт: заводить и закрывать
	RightWarehouses = "warehouses" // внутренние склады
	RightCZ         = "cz"         // Честный знак: маркируемость товара, состояние
	RightUsers      = "users"      // пользователи, должности и мониторинг
)

// Rights — все права, в порядке показа в карточке должности.
var Rights = []string{
	RightTSD, RightPortal, RightCatalog, RightDocuments, RightProblems, RightStocktake,
	RightWarehouses, RightCZ, RightUsers,
}

// Постоянные id стартовых должностей (миграция 33): «Кладовщик» — должность по умолчанию.
const (
	PositionAdminID  = "7a000000-0000-4000-8000-000000000001"
	PositionWorkerID = "7a000000-0000-4000-8000-000000000002"
)

// Ошибки пользователей и должностей (ADHOC-49). Тексты — для экрана портала.
var (
	ErrInvalidPosition   = errors.New("должность задана неверно: нужно название, права — из списка")
	ErrPositionNotFound  = errors.New("должность не найдена")
	ErrPositionSystem    = errors.New("должность «Администратор» не меняется и не удаляется")
	ErrPositionNameTaken = errors.New("должность с таким названием уже есть")
	ErrPositionInUse     = errors.New("на должности есть пользователи — сначала переведите их")
	ErrInvalidUser       = errors.New("пользователь задан неверно")
	ErrUserMissing       = errors.New("пользователь не найден")
	ErrBadgeTaken        = errors.New("бейдж уже выдан другому пользователю")
	ErrUsernameTaken     = errors.New("логин уже занят")
	ErrLastAdmin         = errors.New("это последний активный администратор — система осталась бы без управления")
	ErrSelfBlock         = errors.New("заблокировать себя нельзя")
)

// User — учётная запись. Поля с тегами db — для скана строк pgx (RowToStructByName).
type User struct {
	ID             string    `db:"id"`              // uuid (как текст)
	Login          string    `db:"login"`           // первые 8 цифр бейджа (пусто у входа по паролю)
	Username       string    `db:"username"`        // логин для входа по паролю (пусто у работника по бейджу)
	PasswordHash   string    `db:"password_hash"`   // argon2-хеш секрета/пароля
	FullName       string    `db:"full_name"`       // ФИО → «исполнитель» в отчётах
	PositionID     string    `db:"position_id"`     // должность (ADHOC-49)
	PositionName   string    `db:"position_name"`   //
	PositionSystem bool      `db:"position_system"` // «Администратор» — все права
	PositionRights []string  `db:"position_rights"` // права должности, как записаны
	IsActive       bool      `db:"is_active"`       // блокировка/«удаление» = false
	CreatedAt      time.Time `db:"created_at"`
	UpdatedAt      time.Time `db:"updated_at"`
}

// UserRights — действующие права: у системной должности — все, в том числе новые.
func UserRights(system bool, rights []string) []string {
	if system {
		return slices.Clone(Rights)
	}
	out := make([]string, 0, len(rights))
	for _, r := range Rights { // порядок показа, неизвестное отброшено
		if slices.Contains(rights, r) {
			out = append(out, r)
		}
	}
	return out
}

// Rights — действующие права пользователя.
func (u User) Rights() []string { return UserRights(u.PositionSystem, u.PositionRights) }

// Can — есть ли у пользователя право.
func (u User) Can(right string) bool { return slices.Contains(u.Rights(), right) }

// Role — прежняя роль для старых клиентов: admin — у кого право «пользователи и должности».
func (u User) Role() string {
	if u.Can(RightUsers) {
		return RoleAdmin
	}
	return RoleEmployee
}

// Position — должность с правами (ADHOC-49).
type Position struct {
	ID       string
	Name     string
	Rights   []string // действующие: у системной — все
	IsSystem bool
	Users    int // сколько пользователей на должности, вместе с заблокированными
}

// PositionInput — название и права должности.
type PositionInput struct {
	Name   string
	Rights []string
}

// UserListItem — пользователь в списке портала: без хеша, с должностью и способом входа.
type UserListItem struct {
	ID           string
	FullName     string
	PositionID   string
	PositionName string
	Login        string // первые 8 цифр бейджа; пусто — вход по паролю
	Username     string
	IsActive     bool
	CreatedAt    time.Time
}

// UserCreateInput — новый пользователь: ровно один способ входа — бейдж (16 цифр) или логин с
// паролем.
type UserCreateInput struct {
	FullName   string
	PositionID string
	Badge      string
	Username   string
	Password   string
	By         string // кто заводит — в audit_log
}

// UserUpdateInput — правка пользователя; nil — поле не меняется. Новый бейдж или пароль
// заменяют прежний вход того же вида.
type UserUpdateInput struct {
	ID         string
	FullName   *string
	PositionID *string
	IsActive   *bool
	Badge      *string
	Password   *string
	By         string
}
