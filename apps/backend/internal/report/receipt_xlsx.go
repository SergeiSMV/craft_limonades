package report

import (
	"bytes"
	"fmt"
	"time"

	"github.com/xuri/excelize/v2"

	"craftwms/internal/model"
)

// Лист и колонки формы «Поступление» (P4-10).
const receiptSheet = "Поступление"

var receiptHeaders = []string{"Ячейка", "Код", "Наименование", "Дата выпуска", "Количество"}

// msk — московское время для даты документа. Фиксированный сдвиг, а не LoadLocation: в образе
// бэкенда базы часовых поясов может не быть, а сервер работает в UTC — без перевода приёмка,
// проведённая после 21:00 МСК, получила бы в документе завтрашнюю дату.
var msk = time.FixedZone("MSK", 3*60*60)

// BuildReceiptXLSX собирает .xlsx «Поступления» по снимку документа.
//
// Раскладка: шапка (склад, поставщик, документ поставщика, исполнитель, дата) — затем таблица товаров по партиям
// с ячейкой размещения. Шапка отдельными строками, а не колонками в каждой строке, как у ввода
// остатков: у ввода склад — единственное общее поле, а у поступления их четыре, и повтор
// четырёх одинаковых колонок в каждой строке заслонил бы сами товары.
func BuildReceiptXLSX(s model.ReportSnapshot) ([]byte, error) {
	f := excelize.NewFile()
	defer func() { _ = f.Close() }()
	if err := f.SetSheetName(f.GetSheetName(0), receiptSheet); err != nil {
		return nil, fmt.Errorf("переименовать лист: %w", err)
	}

	supplier := s.Supplier
	if supplier == "" {
		supplier = "без поставщика"
	}
	header := [][2]string{
		{"Поступление", ""},
		{"Склад", s.WarehouseName},
		{"Поставщик", supplier},
	}
	// Документ-основание (ADHOC-23) — сразу под поставщиком: оператор заносит в 1С именно его.
	// Снимок до ADHOC-23 документа не несёт, и строки нет.
	if s.DocNumber != "" {
		header = append(header, [2]string{
			"Документ поставщика", "№ " + s.DocNumber + " от " + formatDate(s.DocDate),
		})
	}
	header = append(header,
		[2]string{"Исполнитель", s.Executor},
		[2]string{"Дата", s.CreatedAt.In(msk).Format("02.01.2006 15:04")},
	)
	for r, kv := range header {
		_ = f.SetCellValue(receiptSheet, cellName(1, r+1), kv[0])
		if kv[1] != "" {
			_ = f.SetCellValue(receiptSheet, cellName(2, r+1), kv[1])
		}
	}

	// Таблица — через строку после шапки.
	top := len(header) + 2
	for i, h := range receiptHeaders {
		_ = f.SetCellValue(receiptSheet, cellName(i+1, top), h)
	}
	for r, row := range s.Rows {
		code := ""
		if row.GoodCode != nil {
			code = *row.GoodCode
		}
		values := []any{
			row.CellAddress,
			code,
			row.GoodName,
			formatDate(row.ProductionDate),
			qtyValue(row.Qty),
		}
		for i, v := range values {
			_ = f.SetCellValue(receiptSheet, cellName(i+1, top+1+r), v)
		}
	}

	var buf bytes.Buffer
	if err := f.Write(&buf); err != nil {
		return nil, fmt.Errorf("запись xlsx: %w", err)
	}
	return buf.Bytes(), nil
}

// cellName — адрес ячейки листа по номеру колонки и строки (с единицы).
func cellName(col, row int) string {
	name, _ := excelize.CoordinatesToCellName(col, row)
	return name
}
