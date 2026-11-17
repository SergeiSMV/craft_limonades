package model

import "errors"

// Ошибки страницы «Ячейки» (ADHOC-57, ADHOC-61): ввод портала - 400, состояние склада - 409.
// Тексты - для экрана портала.
var (
	ErrNoCellsSelected = errors.New("не выбраны ячейки")
	ErrEmptyCellsPatch = errors.New("нечего менять: не задана ни одна галочка")
	ErrTooManyCells    = errors.New("слишком много ячеек за один раз")
	ErrInvalidCellIDs  = errors.New("id ячейки должен быть UUID")
	// ErrInvalidFloorAddress - адрес напольной ячейки не вида «D-Н-П» (ADHOC-61).
	ErrInvalidFloorAddress = errors.New("адрес напольной ячейки - стеллаж и «-Н-П», например «D-Н-П»")
	// ErrForeignCells - в патче есть ячейки не этого склада, неактивные, ячейка приёмки или
	// несуществующие: менять такие нельзя, и тихо пропускать их тоже нельзя.
	ErrForeignCells = errors.New("ячейки не найдены на складе")
	// ErrCellExists - на складе уже есть активная ячейка с таким адресом.
	ErrCellExists = errors.New("ячейка с таким адресом уже есть на складе")
	// ErrCellNotEmpty - в ячейке лежит товар или стоят короба: удалить её нельзя.
	ErrCellNotEmpty = errors.New("в ячейке есть товар или короба - удалить нельзя")
)

// CellSetup - ячейка на странице «Ячейки» портала (ADHOC-57): адрес, стеллаж и настройки
// этикетки на балку. Отдельна от Cell: Cell кормит ТСД и не должна тянуть поля печати.
type CellSetup struct {
	ID       string  `json:"id"`
	Address  string  `json:"address"`
	RackID   *string `json:"rack_id"`   // null - ячейка без стеллажа
	RackCode *string `json:"rack_code"` // «B-01»
	// IsFloor - нижняя ячейка: стрелка вниз на этикетке (тот же признак, что «напольная» на ТСД).
	IsFloor      bool `json:"is_floor"`
	LabelSmall   bool `json:"label_small"`   // малая балка: этикетка 190×46 мм вместо 190×69
	LabelBarcode bool `json:"label_barcode"` // штрих-код Code128 на этикетке балки
	// SideCard - строка на карточке своего стеллажа (полоса с адресами и штрих-кодами на боковой
	// опоре). Решение 2026-11-05: галочка у ячейки; у ячейки без стеллажа всегда false.
	SideCard bool `json:"side_card"`
	// IsFloorStorage - напольное хранение у стеллажа (адрес на «-Н-П», ADHOC-61): ведётся вручную,
	// стеллажа и карточки у неё нет, на этикетке - QR вместо Code128 (кириллицу Code128 не кодирует).
	IsFloorStorage bool `json:"is_floor_storage"`
}

// Rack - стеллаж склада: только группировка ячеек. Карточка на стойку печатается на стеллаж,
// где есть ячейки с галочкой SideCard.
type Rack struct {
	ID   string `json:"id"`
	Code string `json:"code"`
}

// CellsSetup - всё для страницы «Ячейки»: ячейки склада (без ячейки приёмки) и его стеллажи.
type CellsSetup struct {
	Warehouse string      `json:"warehouse"` // код склада
	Cells     []CellSetup `json:"cells"`
	Racks     []Rack      `json:"racks"`
}

// CellSettingsPatch - массовое изменение галочек у ячеек. nil - поле не меняется. SideCard=true
// ставится только ячейкам со стеллажом: у ячейки без стеллажа карточки нет.
type CellSettingsPatch struct {
	CellIDs      []string `json:"cell_ids"`
	LabelSmall   *bool    `json:"label_small"`
	IsFloor      *bool    `json:"is_floor"`
	LabelBarcode *bool    `json:"label_barcode"`
	SideCard     *bool    `json:"side_card"`
}

// Empty - в патче нечего менять.
func (p CellSettingsPatch) Empty() bool {
	return p.LabelSmall == nil && p.IsFloor == nil && p.LabelBarcode == nil && p.SideCard == nil
}

// CellSettingsResult - сколько ячеек реально изменено.
type CellSettingsResult struct {
	CellsUpdated int `json:"cells_updated"`
}

// FloorCellInput - адрес напольной ячейки при добавлении и переименовании (ADHOC-61).
type FloorCellInput struct {
	Address string `json:"address"`
}

// FloorCell - добавленная или переименованная напольная ячейка.
type FloorCell struct {
	ID      string `json:"id"`
	Address string `json:"address"`
}
