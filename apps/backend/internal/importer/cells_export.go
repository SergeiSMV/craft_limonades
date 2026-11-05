package importer

import (
	"fmt"

	"github.com/xuri/excelize/v2"
)

// ExportCell — ячейка для выгрузки в файл формата rack_labels.
type ExportCell struct {
	Address      string
	RackCode     string // пусто — без стеллажа
	LabelSmall   bool
	IsFloor      bool
	LabelBarcode bool
	SideCard     bool // строка на карточке стеллажа
}

// BuildCellsXLSX собирает .xlsx ячеек в формате rack_labels — тот же, что принимает ParseCells.
//
// Что: лист cells (строка на ячейку) и лист racks (строка на стеллаж). Зачем: выгрузку можно
// поправить в Excel и загрузить обратно, а также напечатать прежним скриптом rack_labels.
// Галочка карточки — колонкой side_card листа cells (при загрузке она главнее листа racks, так
// что круг «выгрузка → загрузка» не меняет состояние); на листе racks side_card = есть ли у
// стеллажа ячейки с галочкой — для скрипта rack_labels, который читает карточку оттуда.
// Как: колонки barcode_value, copies, print в WMS не хранятся и пишутся значениями по умолчанию
// rack_labels (пусто, 1, TRUE) — скрипт без них не читал бы старые файлы, а загрузка их пропускает.
// Булевы — настоящими булевыми ячейками Excel (TRUE/FALSE), как в исходном файле. Порядок строк
// задаёт вызывающий.
func BuildCellsXLSX(cells []ExportCell, racks []RackRow) ([]byte, error) {
	f := excelize.NewFile()
	defer func() { _ = f.Close() }()

	if err := f.SetSheetName("Sheet1", SheetCells); err != nil {
		return nil, err
	}
	cellRows := [][]any{{ColCellID, ColRackID, ColSize, ColArrow, ColBarcode, ColBarcodeValue, ColCopies, ColPrint, ColSideCard}}
	for _, c := range cells {
		size, arrow := SizeLarge, ArrowNone
		if c.LabelSmall {
			size = SizeSmall
		}
		if c.IsFloor {
			arrow = ArrowDown
		}
		cellRows = append(cellRows, []any{c.Address, c.RackCode, size, arrow, c.LabelBarcode, nil, 1, true, c.SideCard})
	}
	if err := writeRows(f, SheetCells, cellRows); err != nil {
		return nil, err
	}

	if _, err := f.NewSheet(SheetRacks); err != nil {
		return nil, err
	}
	rackRows := [][]any{{ColRackID, ColSideCard}}
	for _, r := range racks {
		rackRows = append(rackRows, []any{r.Code, r.SideCard})
	}
	if err := writeRows(f, SheetRacks, rackRows); err != nil {
		return nil, err
	}

	buf, err := f.WriteToBuffer()
	if err != nil {
		return nil, fmt.Errorf("запись xlsx: %w", err)
	}
	return buf.Bytes(), nil
}

// writeRows пишет строки листа начиная с A1.
func writeRows(f *excelize.File, sheet string, rows [][]any) error {
	for i := range rows {
		cell, err := excelize.CoordinatesToCellName(1, i+1)
		if err != nil {
			return err
		}
		if err := f.SetSheetRow(sheet, cell, &rows[i]); err != nil {
			return fmt.Errorf("лист %s, строка %d: %w", sheet, i+1, err)
		}
	}
	return nil
}
