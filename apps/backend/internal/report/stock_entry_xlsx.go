// Package report - генерация Excel-отчётов (P-FastStart). Пока - «ввод остатков» (P-FS-08).
package report

import (
	"bytes"
	"fmt"
	"strconv"
	"time"

	"github.com/xuri/excelize/v2"

	"craftwms/internal/model"
)

// Лист и колонки отчёта «ввод остатков».
const sheetName = "Ввод остатков"

// «Марка» (ADHOC-55) - последней: прежние колонки остаются на своих местах.
var headers = []string{"Склад", "Ячейка", "Код", "Наименование", "Дата выпуска", "Количество", "Марка"}

// BuildStockEntryXLSX формирует .xlsx-отчёт «ввод остатков» по данным закрытой сессии: заголовок +
// строки (склад · ячейка · код · наименование · дата дд.мм.гггг · количество).
func BuildStockEntryXLSX(rep model.StockEntryReport) ([]byte, error) {
	f := excelize.NewFile()
	defer func() { _ = f.Close() }()
	if err := f.SetSheetName(f.GetSheetName(0), sheetName); err != nil {
		return nil, fmt.Errorf("переименовать лист: %w", err)
	}

	// Шапка - номер документа и номер сессии ввода остатков (ADHOC-55), затем через строку
	// таблица.
	header := [][2]string{{"Ввод остатков", docNumber(model.DocPrefixStockEntryDoc, rep.Number)}}
	if rep.SourceNumber > 0 {
		header = append(header, [2]string{"Операция", model.DocNumber(model.DocPrefixStockEntry, rep.SourceNumber)})
	}
	for r, kv := range header {
		_ = f.SetCellValue(sheetName, cellName(1, r+1), kv[0])
		if kv[1] != "" {
			_ = f.SetCellValue(sheetName, cellName(2, r+1), kv[1])
		}
	}
	top := len(header) + 2

	// Заголовок таблицы.
	for i, h := range headers {
		_ = f.SetCellValue(sheetName, cellName(i+1, top), h)
	}

	// Строки.
	for r, row := range rep.Rows {
		code := ""
		if row.GoodCode != nil {
			code = *row.GoodCode
		}
		values := []any{
			rep.WarehouseName,
			row.CellAddress,
			code,
			row.GoodName,
			formatDate(row.ProductionDate),
			qtyValue(row.Qty),
			row.Mark,
		}
		for i, v := range values {
			_ = f.SetCellValue(sheetName, cellName(i+1, top+1+r), v)
		}
	}

	var buf bytes.Buffer
	if err := f.Write(&buf); err != nil {
		return nil, fmt.Errorf("запись xlsx: %w", err)
	}
	return buf.Bytes(), nil
}

// formatDate: ISO YYYY-MM-DD → дд.мм.гггг (как в остальном UI). Неожиданный формат - как есть.
func formatDate(iso string) string {
	t, err := time.Parse("2006-01-02", iso)
	if err != nil {
		return iso
	}
	return t.Format("02.01.2006")
}

// qtyValue: число, если парсится (в Excel - числовая ячейка для сверки), иначе строка как есть.
func qtyValue(s string) any {
	if v, err := strconv.ParseFloat(s, 64); err == nil {
		return v
	}
	return s
}
