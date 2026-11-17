package demo

import (
	"fmt"

	"craftwms/internal/model"
	"craftwms/internal/repository"
)

// demoGood - товар демо-справочника. Код - как его пишет импорт номенклатуры 1С (без ведущих
// нулей), в реестре на сборку он же с нулями до 11 знаков.
type demoGood struct {
	code, name, group string
	supplier          int // индекс в demoSuppliers
}

// Выдуманный справочник: лимонады, сиропы и упаковка - то, что лежит на складе пилота, но
// без настоящих наименований, кодов и поставщиков.
var (
	demoGroups    = []string{"Лимонады", "Сиропы", "Упаковка"}
	demoSuppliers = []string{"ООО «Северный ключ»", "ООО «Ягодный край»", "ИП Луговой"}
	demoGoods     = []demoGood{
		{"90101", "Лимонад «Тархун» 0,5 л", "Лимонады", 0},
		{"90102", "Лимонад «Дюшес» 0,5 л", "Лимонады", 0},
		{"90103", "Лимонад «Барбарис» 0,5 л", "Лимонады", 0},
		{"90104", "Лимонад «Крем-сода» 0,5 л", "Лимонады", 0},
		{"90105", "Лимонад «Лимон-лайм» 0,5 л", "Лимонады", 0},
		{"90106", "Лимонад «Груша» 1 л", "Лимонады", 0},
		{"90107", "Лимонад «Малина» 1 л", "Лимонады", 1},
		{"90108", "Лимонад «Облепиха» 1 л", "Лимонады", 1},
		{"90109", "Лимонад «Имбирь» 0,33 л", "Лимонады", 1},
		{"90110", "Лимонад «Клюква» 0,33 л", "Лимонады", 1},
		{"90201", "Сироп «Ваниль» 0,7 л", "Сиропы", 1},
		{"90202", "Сироп «Карамель» 0,7 л", "Сиропы", 1},
		{"90203", "Сироп «Мята» 0,7 л", "Сиропы", 1},
		{"90204", "Сироп «Лесной орех» 0,7 л", "Сиропы", 1},
		{"90301", "Коробка гофро 12 бут.", "Упаковка", 2},
		{"90302", "Коробка гофро 20 бут.", "Упаковка", 2},
		{"90303", "Плёнка стрейч 500 мм", "Упаковка", 2},
		{"90304", "Пакет фасовочный", "Упаковка", 2},
	}
)

// catalog - группы, поставщики, товары с внутренними ШК и физический склад.
//
// Как: теми же Upsert, что импорт номенклатуры; ШК - внутренние EAN-13 (префикс 20), как
// выдаёт портал товару без своего ШК: их можно напечатать и сканировать.
func (s *seeder) catalog() error {
	groupRepo := repository.NewNomenclatureGroupRepository(s.pool)
	supplierRepo := repository.NewSupplierRepository(s.pool)
	goodsRepo := repository.NewGoodsRepository(s.pool)
	barcodes := repository.NewBarcodeRepository(s.pool)

	groups := map[string]string{}
	for i, name := range demoGroups {
		id, err := groupRepo.Upsert(s.ctx, s.pool, fmt.Sprintf("9%02d", i+1), name, nil)
		if err != nil {
			return err
		}
		groups[name] = id
	}
	for _, name := range demoSuppliers {
		id, err := supplierRepo.Upsert(s.ctx, s.pool, name)
		if err != nil {
			return err
		}
		s.suppliers = append(s.suppliers, id)
	}
	for _, g := range demoGoods {
		group, supplier := groups[g.group], s.suppliers[g.supplier]
		if _, err := goodsRepo.Upsert(s.ctx, s.pool, g.code, g.name, g.name, "шт", &group, &supplier); err != nil {
			return err
		}
		id, err := s.scan(`SELECT id::text FROM goods WHERE code = $1`, g.code)
		if err != nil {
			return err
		}
		s.goods[g.code] = id
		if _, err := barcodes.CreateInternal(s.ctx, id); err != nil {
			return err
		}
	}

	warehouses := repository.NewWarehouseRepository(s.pool)
	var err error
	if s.warehouseID, err = warehouses.Upsert(s.ctx, s.pool, model.DefaultWarehouseCode, model.DemoWarehouseName); err != nil {
		return err
	}
	if s.mainIWH, err = s.scan(`SELECT id::text FROM internal_warehouses WHERE is_default`); err != nil {
		return err
	}
	s.defectIWH, err = s.scan(`SELECT id::text FROM internal_warehouses WHERE code = 'DEFECT'`)
	return err
}

// cellsAndRacks - три стеллажа по четыре секции в три полки, напольная ячейка, ячейки приёмки
// и отгрузки. Адрес «A-01-1»: стеллаж-секция-полка, как в файле rack_labels.
func (s *seeder) cellsAndRacks() error {
	cells := repository.NewCellRepository(s.pool)
	for _, rack := range []string{"A", "B", "C"} {
		for sec := 1; sec <= 4; sec++ {
			code := fmt.Sprintf("%s-%02d", rack, sec)
			rackID, _, err := cells.UpsertRack(s.ctx, s.pool, s.warehouseID, code)
			if err != nil {
				return err
			}
			for shelf := 1; shelf <= 3; shelf++ {
				addr := fmt.Sprintf("%s-%d", code, shelf)
				side := true
				c := model.CellSetup{Address: addr, IsFloor: shelf == 1, LabelBarcode: true}
				if _, err := cells.UpsertSetup(s.ctx, s.pool, s.warehouseID, &rackID, c, &side); err != nil {
					return err
				}
			}
		}
	}
	if _, err := cells.CreateFloorCell(s.ctx, s.pool, s.warehouseID, "A"+model.FloorStorageSuffix); err != nil {
		return err
	}
	if _, err := cells.EnsureDefault(s.ctx, s.pool, s.warehouseID); err != nil {
		return err
	}
	if _, err := cells.EnsureShipping(s.ctx, s.pool, s.warehouseID); err != nil {
		return err
	}
	rows, err := s.pool.Query(s.ctx, `SELECT address, id::text FROM cells WHERE warehouse_id = $1::uuid`, s.warehouseID)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var addr, id string
		if err := rows.Scan(&addr, &id); err != nil {
			return err
		}
		s.cells[addr] = id
	}
	return rows.Err()
}
