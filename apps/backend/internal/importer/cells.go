package importer

import (
	"fmt"
	"io"
	"strings"

	"github.com/xuri/excelize/v2"
)

// CellRow — распарсенная физическая ячейка склада из файла.
type CellRow struct {
	Address string // адрес ячейки (латиница, напр. «M1-1-2-1») — часть ключа апсерта
	IsFloor bool   // напольная ячейка (колонка «floor») — для будущей PDF-стрелки вниз
}

// CellsParseResult — итог парсинга файла ячеек: принятые ячейки и отклонённые строки.
type CellsParseResult struct {
	Cells  []CellRow
	Errors []RowError
}

// Имена колонок файла ячеек (нормализованные). Маппинг по заголовку — устойчив к порядку колонок.
const (
	colCell  = "cell"  // адрес ячейки
	colFloor = "floor" // напольная (true/false)
)

// ParseCells читает файл ячеек (.xlsx: колонки «cell», «floor») и раскладывает строки в ячейки.
//
// Что: разбирает выгрузку физических ячеек одного склада (внешний/внутренний склад в файле не заданы —
// приходят параметром импорта). Зачем: заводит статичный справочник ячеек перед пилотом. Как:
// первый лист, заголовок → индексы колонок, дальше строки; проблемные строки не валят импорт,
// а попадают в Errors (отчёт).
func ParseCells(r io.Reader) (*CellsParseResult, error) {
	f, err := excelize.OpenReader(r)
	if err != nil {
		return nil, fmt.Errorf("открыть xlsx: %w", err)
	}
	defer func() { _ = f.Close() }()

	sheet := f.GetSheetName(0)
	if sheet == "" {
		return nil, fmt.Errorf("в файле нет листа")
	}
	rows, err := f.GetRows(sheet)
	if err != nil {
		return nil, fmt.Errorf("чтение строк листа %q: %w", sheet, err)
	}
	if len(rows) == 0 {
		return nil, fmt.Errorf("файл пуст")
	}

	// 1. Заголовок (строка 0) → индексы колонок по имени.
	cols, err := cellsHeaderIndex(rows[0])
	if err != nil {
		return nil, err
	}

	res := &CellsParseResult{}
	for i := 1; i < len(rows); i++ {
		rowNum := i + 1 // 1-based, как в Excel
		address := colValue(rows[i], cols, colCell)
		floorRaw := colValue(rows[i], cols, colFloor)

		if address == "" && floorRaw == "" {
			continue // пустая строка
		}
		if address == "" {
			res.Errors = append(res.Errors, RowError{Row: rowNum, Message: "ячейка без адреса — пропущена"})
			continue
		}
		isFloor, ok := parseBool(floorRaw)
		if !ok {
			res.Errors = append(res.Errors, RowError{
				Row:     rowNum,
				Message: fmt.Sprintf("ячейка %q: не распознан признак floor %q — пропущена", address, floorRaw),
			})
			continue
		}
		res.Cells = append(res.Cells, CellRow{Address: address, IsFloor: isFloor})
	}
	return res, nil
}

// cellsHeaderIndex строит карту «нормализованное имя колонки → индекс» и проверяет обязательные колонки.
func cellsHeaderIndex(header []string) (map[string]int, error) {
	cols := map[string]int{}
	for idx, h := range header {
		if n := norm(h); n != "" {
			cols[n] = idx
		}
	}
	for _, req := range []string{colCell, colFloor} {
		if _, ok := cols[req]; !ok {
			return nil, fmt.Errorf("в заголовке файла нет обязательной колонки %q (найдено: %s)", req, strings.Join(keys(cols), ", "))
		}
	}
	return cols, nil
}

// colValue возвращает обрезанное значение ячейки по имени колонки (пусто, если колонки нет или строка короче).
func colValue(row []string, cols map[string]int, colName string) string {
	idx, ok := cols[colName]
	if !ok || idx >= len(row) {
		return ""
	}
	return strings.TrimSpace(row[idx])
}

// parseBool разбирает признак floor. Пусто → false (ячейка не напольная). Возвращает ok=false
// для нераспознанного значения — такую строку отправляем в отчёт, а не тихо считаем false.
func parseBool(s string) (val bool, ok bool) {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "", "false", "0", "нет":
		return false, true
	case "true", "1", "да":
		return true, true
	default:
		return false, false
	}
}
