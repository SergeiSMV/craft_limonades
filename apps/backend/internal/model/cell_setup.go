package model

// CellSetup — ячейка на странице «Ячейки» портала (ADHOC-57): адрес, стеллаж и настройки
// этикетки на балку. Отдельна от Cell: Cell кормит ТСД и не должна тянуть поля печати.
type CellSetup struct {
	ID       string  `json:"id"`
	Address  string  `json:"address"`
	RackID   *string `json:"rack_id"`   // null — ячейка без стеллажа
	RackCode *string `json:"rack_code"` // «B-01»
	// IsFloor — нижняя ячейка: стрелка вниз на этикетке (тот же признак, что «напольная» на ТСД).
	IsFloor      bool `json:"is_floor"`
	LabelSmall   bool `json:"label_small"`   // малая балка: этикетка 190×46 мм вместо 190×69
	LabelBarcode bool `json:"label_barcode"` // штрих-код Code128 на этикетке балки
}

// Rack — стеллаж склада: код и признак «карточка на стойку» (полоса со всеми адресами
// стеллажа и их штрих-кодами на боковой опоре).
type Rack struct {
	ID       string `json:"id"`
	Code     string `json:"code"`
	SideCard bool   `json:"side_card"`
}

// CellsSetup — всё для страницы «Ячейки»: ячейки склада (без ячейки приёмки) и его стеллажи.
type CellsSetup struct {
	Warehouse string      `json:"warehouse"` // код склада
	Cells     []CellSetup `json:"cells"`
	Racks     []Rack      `json:"racks"`
}

// CellSettingsPatch — массовое изменение галочек у ячеек. nil — поле не меняется. SideCard
// относится к стеллажам выбранных ячеек: галочка одна на весь стеллаж.
type CellSettingsPatch struct {
	CellIDs      []string `json:"cell_ids"`
	LabelSmall   *bool    `json:"label_small"`
	IsFloor      *bool    `json:"is_floor"`
	LabelBarcode *bool    `json:"label_barcode"`
	SideCard     *bool    `json:"side_card"`
}

// Empty — в патче нечего менять.
func (p CellSettingsPatch) Empty() bool {
	return p.LabelSmall == nil && p.IsFloor == nil && p.LabelBarcode == nil && p.SideCard == nil
}

// CellSettingsResult — сколько ячеек и стеллажей изменено.
type CellSettingsResult struct {
	CellsUpdated int `json:"cells_updated"`
	RacksUpdated int `json:"racks_updated"`
}
