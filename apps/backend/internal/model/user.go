// Package model — сущности предметной области (чистые структуры без внешних зависимостей).
package model

import (
	"errors"
	"slices"
	"strings"
	"time"
)

// Роли пользователя — прежняя модель доступа (до ADHOC-49). Теперь роль не хранится, а
// выводится из прав должности: admin — у кого есть право «должности и пользователи». Её ещё
// читают старые сборки ТСД и портала (`/auth/me`) и метка события Bugsink.
const (
	RoleEmployee = "employee"
	RoleAdmin    = "admin"
)

// Права должности — действия по разделам (ADHOC-50, миграция 34): код
// «приложение.раздел.действие». Группы дерева (раздел, приложение) не хранятся: галочку раздела
// рисует портал. Список совпадает с ограничением positions.rights.
const (
	RightNomenclatureView   = "portal.nomenclature.view"   // Номенклатура склада: смотреть (ADHOC-56)
	RightNomenclatureImport = "portal.nomenclature.import" // Номенклатура: загружать из 1С
	RightStockView          = "portal.stock.view"          // Остатки склада: смотреть (ADHOC-56)
	RightReceiptView        = "portal.receipt.view"        // Приход: смотреть документы и историю
	RightReceiptDownload    = "portal.receipt.download"    // Приход: скачивать
	RightReceiptPost        = "portal.receipt.post"        // Приход: проводить
	RightStocktakeView      = "portal.stocktake.view"      // Пересчёты: смотреть ход
	RightStocktakeManage    = "portal.stocktake.manage"    // Пересчёты: заводить и закрывать
	RightStocktakeDocView   = "portal.stocktake_doc.view"
	RightStocktakeDocLoad   = "portal.stocktake_doc.download"
	RightStocktakeDocPost   = "portal.stocktake_doc.post"
	RightStockEntryDocView  = "portal.stock_entry_doc.view"
	RightStockEntryDocLoad  = "portal.stock_entry_doc.download"
	RightStockEntryDocPost  = "portal.stock_entry_doc.post"
	RightCellsImport        = "portal.cells.import" // Ячейки: загружать
	RightCellsLabels        = "portal.cells.labels" // Ячейки: печатать этикетки
	RightCellsEdit          = "portal.cells.edit"   // Ячейки: изменять настройки этикеток (ADHOC-57)
	RightMovementView       = "portal.movement.view"
	RightMovementDownload   = "portal.movement.download"
	RightMovementPost       = "portal.movement.post"
	RightProblemsView       = "portal.problems.view"    // Проблемы склада: смотреть с фото
	RightProblemsResolve    = "portal.problems.resolve" // Проблемы склада: решать и проводить
	RightPickingView        = "portal.picking.view"     // Сборка-отгрузка: смотреть заказы и детали (P8-02)
	RightPickingLoad        = "portal.picking.load"     // Сборка-отгрузка: загружать реестр 1С
	RightPickingDownload    = "portal.picking.download" // Сборка-отгрузка: выгружать Excel
	RightPickingRelease     = "portal.picking.release"  // Сборка-отгрузка: снимать заказ с исполнителя (P8-03)
	RightSettingsWarehouses = "portal.settings.warehouses"
	RightSettingsUsers      = "portal.settings.users" // должности и пользователи
	// RightSettingsProblemReasons — причины проблем и варианты решения (ADHOC-55).
	RightSettingsProblemReasons = "portal.settings.problem_reasons"

	RightTSDReceipt         = "tsd.receipt"
	RightTSDMovement        = "tsd.movement"
	RightTSDPutaway         = "tsd.tasks.putaway" // размещение и возврат поставщику
	RightTSDStocktakeCount  = "tsd.tasks.stocktake_count"
	RightTSDStocktakeManage = "tsd.tasks.stocktake_manage"
	RightTSDPickingReturn   = "tsd.tasks.picking_return" // вернуть на места после правки реестра (P9-07-1)
	RightTSDStockView       = "tsd.stock.view"
	RightTSDStockCZMarked   = "tsd.stock.cz_marked" // признак «маркируемый (ЧЗ)»
	RightTSDStockRegrade    = "tsd.stock.regrade"   // перепривязать ШК маркируемого товара (ADHOC-53)
	RightTSDStockEntry      = "tsd.stock_entry"
	RightTSDProblemsView    = "tsd.problems.view"
	RightTSDProblemsMark    = "tsd.problems.mark"
	RightTSDPicking         = "tsd.picking"         // собирать и отгружать заказы (P8-02)
	RightTSDPickingReprint  = "tsd.picking.reprint" // повторно печатать ярлык короба отгрузки
)

// Префиксы приложений: «любое право портала / ТСД».
const (
	RightsPortal = "portal."
	RightsTSD    = "tsd."
)

// Rights — все действия, в порядке дерева портала.
var Rights = []string{
	RightNomenclatureView, RightNomenclatureImport,
	RightStockView,
	RightReceiptView, RightReceiptDownload, RightReceiptPost,
	RightStocktakeView, RightStocktakeManage,
	RightStocktakeDocView, RightStocktakeDocLoad, RightStocktakeDocPost,
	RightStockEntryDocView, RightStockEntryDocLoad, RightStockEntryDocPost,
	RightCellsImport, RightCellsLabels, RightCellsEdit,
	RightMovementView, RightMovementDownload, RightMovementPost,
	RightProblemsView, RightProblemsResolve,
	RightPickingView, RightPickingLoad, RightPickingDownload, RightPickingRelease,
	RightSettingsWarehouses, RightSettingsProblemReasons, RightSettingsUsers,
	RightTSDReceipt, RightTSDMovement,
	RightTSDPutaway, RightTSDStocktakeCount, RightTSDStocktakeManage, RightTSDPickingReturn,
	RightTSDStockView, RightTSDStockCZMarked, RightTSDStockRegrade, RightTSDStockEntry,
	RightTSDProblemsView, RightTSDProblemsMark,
	RightTSDPicking, RightTSDPickingReprint,
}

// DocumentAction — действие с документом для 1С.
type DocumentAction int

// Действия с документом: смотреть (список и история), скачивать, проводить.
const (
	DocView DocumentAction = iota
	DocDownload
	DocPost
)

// DocumentRight — право на действие с документом вида kind; пусто — вид неизвестен.
func DocumentRight(kind string, a DocumentAction) string {
	rights := map[string][3]string{
		ReportKindReceipt:    {RightReceiptView, RightReceiptDownload, RightReceiptPost},
		ReportKindMovement:   {RightMovementView, RightMovementDownload, RightMovementPost},
		ReportKindStocktake:  {RightStocktakeDocView, RightStocktakeDocLoad, RightStocktakeDocPost},
		ReportKindStockEntry: {RightStockEntryDocView, RightStockEntryDocLoad, RightStockEntryDocPost},
	}[kind]
	return rights[a]
}

// Access — доступ пользователя на момент запроса: действующие права, системная ли должность,
// активен ли.
type Access struct {
	Rights []string
	System bool
	Active bool
}

// Can — есть ли право.
func (a Access) Can(right string) bool { return slices.Contains(a.Rights, right) }

// CanAny — есть ли хоть одно из прав; право с точкой на конце — префикс: «portal.» — любое
// право портала, «tsd.» — любое право ТСД.
func (a Access) CanAny(rights ...string) bool {
	for _, want := range rights {
		for _, r := range a.Rights {
			if r == want || (strings.HasSuffix(want, ".") && strings.HasPrefix(r, want)) {
				return true
			}
		}
	}
	return false
}

// OperationRights — права, любое из которых пускает операцию очереди вида kind (ADHOC-50).
// Привязка и отвязка ШК и неизвестный вид — любое право ТСД: ШК привязывают и в приёмке, и в
// остатках, и во вводе остатков; неизвестный вид отклонит сам разбор операции.
func OperationRights(kind string) []string {
	switch kind {
	case "receipt_submit":
		return []string{RightTSDReceipt}
	case "putaway_submit", "return_submit":
		return []string{RightTSDPutaway}
	case "movement_submit":
		return []string{RightTSDMovement}
	case "problem_submit":
		return []string{RightTSDProblemsMark}
	case "stocktake_cell_submit":
		return []string{RightTSDStocktakeCount}
	case "picking_pick":
		return []string{RightTSDPicking}
	case "picking_unpick":
		// Взятое удалённого заказа «в работе» возвращает задание «вернуть на места» (P9-07-1).
		return []string{RightTSDPicking, RightTSDPickingReturn}
	case "picking_return":
		return []string{RightTSDPickingReturn}
	case "stock_entry_start", "stock_entry_checkpoint", "stock_entry_finalize":
		return []string{RightTSDStockEntry}
	default:
		return []string{RightsTSD}
	}
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

// Role — прежняя роль для старых клиентов: admin — у кого право «должности и пользователи».
func (u User) Role() string {
	if u.Can(RightSettingsUsers) {
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
