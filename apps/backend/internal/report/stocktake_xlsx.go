package report

import (
	"bytes"
	"fmt"

	"github.com/xuri/excelize/v2"

	"craftwms/internal/model"
)

// Листы и колонки формы «Инвентаризация» (P10-05).
const (
	stocktakeSheet     = "Инвентаризация"
	stocktakeDiffSheet = "Расхождения"
)

var stocktakeHeaders = []string{
	"Ячейка", "Код", "Наименование", "Дата выпуска", "Склад WMS",
	"Ожидалось", "Факт", "Расхождение", "Пометка", "Марка",
}

// stocktakeScopeNames — вид области пересчёта для шапки документа.
var stocktakeScopeNames = map[string]string{
	model.StocktakeScopeCells:             "ячейки",
	model.StocktakeScopeGroup:             "группа номенклатуры",
	model.StocktakeScopeSupplier:          "поставщик",
	model.StocktakeScopeGood:              "товар",
	model.StocktakeScopeInternalWarehouse: "внутренний склад",
	model.StocktakeScopeAll:               "весь склад",
}

// BuildStocktakeXLSX собирает .xlsx «Инвентаризации» по снимку документа (P10-05).
//
// Раскладка: шапка (пересчёт, склад, область, кто закрыл, дата) и таблица всех подсчитанных
// позиций — ожидалось, факт, расхождение; второй лист — только строки с расхождением и
// пометками: по нему расхождения заносят в 1С. Короба в документе развёрнуты в состав — 1С знает
// товар, а не короба; неподсчитанная ячейка — строкой «не считалась».
func BuildStocktakeXLSX(s model.ReportSnapshot) ([]byte, error) {
	f := excelize.NewFile()
	defer func() { _ = f.Close() }()
	if err := f.SetSheetName(f.GetSheetName(0), stocktakeSheet); err != nil {
		return nil, fmt.Errorf("переименовать лист: %w", err)
	}
	if _, err := f.NewSheet(stocktakeDiffSheet); err != nil {
		return nil, fmt.Errorf("лист расхождений: %w", err)
	}

	scope := stocktakeScopeNames[s.ScopeKind]
	if scope == "" {
		scope = s.ScopeKind
	}
	header := [][2]string{
		{"Инвентаризация", docNumber(model.DocPrefixStocktakeDoc, s.Number)},
		{"Пересчёт", model.DocNumber(model.DocPrefixStocktake, s.StocktakeNumber)},
		{"Склад", s.WarehouseName},
		{"Область", scope},
		{"Закрыл", s.Executor},
		{"Дата", s.CreatedAt.In(msk).Format("02.01.2006 15:04")},
	}
	var diffs []model.ReportSnapshotRow
	for _, row := range s.Rows {
		if (row.Diff != "" && qtyValue(row.Diff) != float64(0)) || row.Note != "" {
			diffs = append(diffs, row)
		}
	}
	writeStocktakeSheet(f, stocktakeSheet, header, s.Rows)
	writeStocktakeSheet(f, stocktakeDiffSheet, header, diffs)

	var buf bytes.Buffer
	if err := f.Write(&buf); err != nil {
		return nil, fmt.Errorf("запись xlsx: %w", err)
	}
	return buf.Bytes(), nil
}

// writeStocktakeSheet пишет на лист шапку и таблицу строк — через строку после шапки.
func writeStocktakeSheet(f *excelize.File, sheet string, header [][2]string, rows []model.ReportSnapshotRow) {
	for r, kv := range header {
		_ = f.SetCellValue(sheet, cellName(1, r+1), kv[0])
		_ = f.SetCellValue(sheet, cellName(2, r+1), kv[1])
	}
	top := len(header) + 2
	for i, h := range stocktakeHeaders {
		_ = f.SetCellValue(sheet, cellName(i+1, top), h)
	}
	for r, row := range rows {
		code := ""
		if row.GoodCode != nil {
			code = *row.GoodCode
		}
		values := []any{
			row.CellAddress, code, row.GoodName, formatDate(row.ProductionDate), row.InternalWarehouse,
			stocktakeQty(row.Expected), stocktakeQty(row.Fact), stocktakeQty(row.Diff), row.Note,
			row.Mark,
		}
		for i, v := range values {
			_ = f.SetCellValue(sheet, cellName(i+1, top+1+r), v)
		}
	}
}

// stocktakeQty — число для числовой ячейки; пусто (строка «не считалась») — пустая ячейка.
func stocktakeQty(s string) any {
	if s == "" {
		return ""
	}
	return qtyValue(s)
}
