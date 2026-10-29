package report

import (
	"bytes"
	"fmt"

	"github.com/xuri/excelize/v2"

	"craftwms/internal/model"
)

// Лист и колонки формы «Движение» (P5-04).
const movementSheet = "Движение"

// «Марка» (ADHOC-55): маркируемый товар — строка на марку; колонка последней, прежние на местах.
var movementHeaders = []string{"Откуда", "Куда", "Код", "Наименование", "Дата выпуска", "Количество", "Марка"}

// movementOperationTitle — операция «Движения» для человека. Незнакомое значение (снимок
// формы из будущей версии) показывается как есть: документ важнее подписи.
func movementOperationTitle(op string) string {
	switch op {
	case model.MovementOperationPutaway:
		return "Размещение"
	case model.MovementOperationMove:
		return "Перемещение"
	case model.MovementOperationReplenish:
		return "Пополнение"
	default:
		return op
	}
}

// BuildMovementXLSX собирает .xlsx «Движения» по снимку документа.
//
// Одна форма на размещение, перемещение и пополнение: операция — строкой шапки, строки у всех
// одинаковые — откуда · куда · товар по партиям · количество. Короба в документе нет: 1С
// про них не знает, они уже разложены по составу. Шапка — отдельными строками, как у
// «Поступления»: общих полей у документа несколько, и повторять их в каждой строке незачем.
func BuildMovementXLSX(s model.ReportSnapshot) ([]byte, error) {
	f := excelize.NewFile()
	defer func() { _ = f.Close() }()
	if err := f.SetSheetName(f.GetSheetName(0), movementSheet); err != nil {
		return nil, fmt.Errorf("переименовать лист: %w", err)
	}

	// Номер документа — рядом с названием формы, номер операции — рядом с её видом (ADHOC-55).
	operation := movementOperationTitle(s.Operation)
	if s.SourceNumber > 0 {
		operation += " " + model.DocNumber(model.OperationPrefix(s.Operation), s.SourceNumber)
	}
	header := [][2]string{
		{"Движение", docNumber(model.DocPrefixMovementDoc, s.Number)},
		{"Операция", operation},
		{"Склад", s.WarehouseName},
	}
	// Основание: задание и то, из чего оно родилось, — приёмка или проблема склада (ADHOC-55).
	// Каждая строка — только если есть: перемещению (P6) задание не обязательно, а приёмка
	// бывает без поставщика.
	if s.TaskNumber > 0 {
		header = append(header, [2]string{"Задание", model.DocNumber(model.DocPrefixTask, s.TaskNumber)})
	}
	if s.ProblemNumber > 0 {
		header = append(header, [2]string{"Проблема склада", model.DocNumber(model.DocPrefixProblem, s.ProblemNumber)})
	}
	if s.Supplier != "" {
		header = append(header, [2]string{"Поставщик", s.Supplier})
	}
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
		_ = f.SetCellValue(movementSheet, cellName(1, r+1), kv[0])
		if kv[1] != "" {
			_ = f.SetCellValue(movementSheet, cellName(2, r+1), kv[1])
		}
	}

	// Таблица — через строку после шапки.
	top := len(header) + 2
	for i, h := range movementHeaders {
		_ = f.SetCellValue(movementSheet, cellName(i+1, top), h)
	}
	for r, row := range s.Rows {
		code := ""
		if row.GoodCode != nil {
			code = *row.GoodCode
		}
		values := []any{
			row.FromCellAddress,
			row.CellAddress,
			code,
			row.GoodName,
			formatDate(row.ProductionDate),
			qtyValue(row.Qty),
			row.Mark,
		}
		for i, v := range values {
			_ = f.SetCellValue(movementSheet, cellName(i+1, top+1+r), v)
		}
	}

	var buf bytes.Buffer
	if err := f.Write(&buf); err != nil {
		return nil, fmt.Errorf("запись xlsx: %w", err)
	}
	return buf.Bytes(), nil
}
