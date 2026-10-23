package model

import "github.com/shopspring/decimal"

// Модели чтения справочников (P1-06). Отдаются клиенту как есть (JSON), поэтому теги — snake_case.
// Отдельны от «пишущих» структур импорта: у чтения свой набор полей (в т.ч. присоединённые имена).

// Good — товар для выдачи клиенту. GroupName/SupplierName присоединены (LEFT JOIN) ради экранов P1-07,
// чтобы карточка товара не делала отдельных запросов за именами группы/поставщика.
type Good struct {
	ID           string  `json:"id"`
	Code         *string `json:"code"` // артикул/Код 1С (может отсутствовать)
	Name         string  `json:"name"`
	FullName     *string `json:"full_name"` // полное наименование
	UOM          string  `json:"uom"`       // единица измерения
	GroupID      *string `json:"group_id"`
	GroupName    *string `json:"group_name"`
	SupplierID   *string `json:"supplier_id"`
	SupplierName *string `json:"supplier_name"`
	IsActive     bool    `json:"is_active"`
	// CZMarked — товар маркируемый (CZ-05): на приёмке и отгрузке требует скан марки ЧЗ, а не ШК.
	CZMarked bool `json:"cz_marked"`
}

// Barcode — привязка ШК к товару для выдачи клиенту (секция «Штрихкоды» в карточке товара, P-FS-12).
type Barcode struct {
	Barcode   string  `json:"barcode"`
	Symbology *string `json:"symbology"` // 'ean13'/'code128'/… или null
}

// BarcodeLink — привязка ШК к товару для выгрузки справочника целиком (кэш устройства, P2-02).
// Отличается от Barcode наличием GoodID: там ШК перечисляются внутри известного товара,
// здесь товар и есть то, что нужно узнать по коду.
type BarcodeLink struct {
	Barcode   string  `json:"barcode"`
	GoodID    string  `json:"good_id"`
	Symbology *string `json:"symbology"`
}

// CellLabel — минимум для печати этикетки ячейки: адрес (в штрихкод + текст) и признак напольной
// (стрелка вниз). Отдельна от Cell — этикетке не нужны id/тип/склад.
type CellLabel struct {
	Address string
	IsFloor bool
}

// NomenclatureGroup — узел дерева групп номенклатуры.
type NomenclatureGroup struct {
	ID       string  `json:"id"`
	Code     string  `json:"code"`
	Name     string  `json:"name"`
	ParentID *string `json:"parent_id"` // null — корень
}

// Supplier — поставщик.
type Supplier struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

// Cell — физическая ячейка склада.
type Cell struct {
	ID          string `json:"id"`
	WarehouseID string `json:"warehouse_id"`
	Address     string `json:"address"`
	Type        string `json:"type"`
	IsFloor     bool   `json:"is_floor"`
	IsActive    bool   `json:"is_active"`
	// IsDefault — ячейка приёмки по умолчанию («С-Н-П», одна на склад). Терминал узнаёт её
	// по флагу из своего кэша и без связи: по ней он находит склад приёмки и показывает
	// кладовщику, куда ляжет товар, если место не выбрано (P4-09).
	IsDefault bool `json:"is_default"`
}

// StockItem — остаток в товарном разрезе для карточки «где лежит товар» (P1-07):
// присоединены адрес ячейки и дата выпуска партии. Qty — decimal (точные дробные кг).
type StockItem struct {
	CellID         string          `json:"cell_id"`
	CellAddress    string          `json:"cell_address"`
	GoodID         string          `json:"good_id"`
	BatchID        string          `json:"batch_id"`
	ProductionDate string          `json:"production_date"` // YYYY-MM-DD
	Qty            decimal.Decimal `json:"qty"`

	// Учётная принадлежность остатка (ADR-0016). Кладовщик должен понимать фактическое
	// количество на складе независимо от того, числится товар основным или браком, поэтому
	// строки не складываются, а показываются с пометкой — итог считается отдельно.
	InternalWarehouseID   string `json:"internal_warehouse_id"`
	InternalWarehouseCode string `json:"internal_warehouse_code"`
	InternalWarehouseName string `json:"internal_warehouse_name"`
	// Флаг, а не сравнение кода на клиенте: справочник пополняется и переименовывается из
	// интерфейса, поэтому зашитый в приложении 'MAIN' сломался бы при первом же переименовании.
	InternalWarehouseIsDefault bool `json:"internal_warehouse_is_default"`
}
