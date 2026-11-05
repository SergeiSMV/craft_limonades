package importer

import (
	"fmt"
	"io"
	"strings"

	"github.com/xuri/excelize/v2"
)

// Листы и колонки файла ячеек — формат проекта rack_labels (ADHOC-57): тот же файл печатался
// скриптом и теперь загружается в портал без правок. Имена колонок нормализуются (регистр,
// пробелы), порядок колонок не важен.
const (
	SheetCells = "cells" // строка на ячейку
	SheetRacks = "racks" // строка на стеллаж

	ColCellID       = "cell_id"       // адрес ячейки — ключ апсерта
	ColRackID       = "rack_id"       // код стеллажа («B-01»); пусто — ячейка без стеллажа
	ColSize         = "size"          // large | small — профиль этикетки (балка)
	ColArrow        = "arrow"         // none | down — стрелка у адреса; down = нижняя ячейка
	ColBarcode      = "barcode"       // печатать ли штрих-код на этикетке балки
	ColBarcodeValue = "barcode_value" // в WMS не хранится: сканер читает сам адрес
	ColCopies       = "copies"        // в WMS не хранится: сколько печатать — решают при печати
	ColPrint        = "print"         // в WMS не хранится: что печатать — решают при печати
	ColSideCard     = "side_card"     // лист racks: печатать ли карточку на стойку

	SizeLarge = "large"
	SizeSmall = "small"
	ArrowNone = "none"
	ArrowDown = "down"
	ArrowUp   = "up"
)

// CellRow — ячейка из листа cells: адрес, стеллаж и настройки этикетки.
type CellRow struct {
	Address      string
	RackCode     string // пусто — без стеллажа
	LabelSmall   bool   // size = small
	IsFloor      bool   // arrow = down — нижняя ячейка (стрелка вниз)
	LabelBarcode bool
}

// RackRow — стеллаж из листа racks.
type RackRow struct {
	Code     string
	SideCard bool
}

// CellsParseResult — итог разбора файла ячеек: принятые ячейки и стеллажи, отклонённые строки.
// HasRacksSheet — был ли в файле лист racks: без него признак «карточка на стойку» у уже
// заведённых стеллажей не трогается.
type CellsParseResult struct {
	Cells         []CellRow
	Racks         []RackRow
	HasRacksSheet bool
	Errors        []RowError
}

// ParseCells читает .xlsx ячеек в формате rack_labels: лист cells (обязателен) и лист racks.
//
// Что: раскладывает строки в ячейки и стеллажи. Зачем: настройки этикеток (балка, стрелка,
// штрих-код) и карточки на стойку загружаются тем же файлом, которым их печатал rack_labels.
// Как: обязательные колонки — cell_id и size; остальные можно опустить, тогда берутся умолчания
// rack_labels (arrow = none, barcode = false). Проблемная строка не валит загрузку, а уходит в
// отчёт с причиной: дубль адреса, неизвестные size или arrow, стрелка вверх (в WMS её нет),
// стеллаж, которого нет на листе racks. Ячейки сопоставляются по строке адреса как есть.
func ParseCells(r io.Reader) (*CellsParseResult, error) {
	f, err := excelize.OpenReader(r)
	if err != nil {
		return nil, fmt.Errorf("открыть xlsx: %w", err)
	}
	defer func() { _ = f.Close() }()

	cellsSheet, racksSheet := findSheet(f, SheetCells), findSheet(f, SheetRacks)
	if cellsSheet == "" {
		return nil, fmt.Errorf("в файле нет листа %q (найдено: %s)", SheetCells, strings.Join(f.GetSheetList(), ", "))
	}

	res := &CellsParseResult{}
	knownRacks := map[string]bool{}
	if racksSheet != "" {
		res.HasRacksSheet = true
		if err := parseRacks(f, racksSheet, res, knownRacks); err != nil {
			return nil, err
		}
	}
	if err := parseCellRows(f, cellsSheet, res, knownRacks); err != nil {
		return nil, err
	}
	return res, nil
}

// parseRacks разбирает лист racks: код стеллажа и признак карточки на стойку. Ошибки строк
// листа racks попадают в отчёт с префиксом листа — номера строк двух листов иначе путаются.
func parseRacks(f *excelize.File, sheet string, res *CellsParseResult, known map[string]bool) error {
	rows, err := f.GetRows(sheet)
	if err != nil {
		return fmt.Errorf("чтение листа %q: %w", sheet, err)
	}
	if len(rows) == 0 {
		return nil
	}
	cols, err := sheetHeader(rows[0], sheet, ColRackID, ColSideCard)
	if err != nil {
		return err
	}
	for i := 1; i < len(rows); i++ {
		code := colValue(rows[i], cols, ColRackID)
		raw := colValue(rows[i], cols, ColSideCard)
		if code == "" && raw == "" {
			continue
		}
		bad := func(msg string) {
			res.Errors = append(res.Errors, RowError{Row: i + 1, Message: "лист racks: " + msg})
		}
		switch {
		case code == "":
			bad("стеллаж без кода — пропущен")
		case known[code]:
			bad(fmt.Sprintf("стеллаж %q повторяется — пропущен", code))
		default:
			sideCard, ok := parseBool(raw)
			if !ok {
				bad(fmt.Sprintf("стеллаж %q: не распознан side_card %q — пропущен", code, raw))
				continue
			}
			known[code] = true
			res.Racks = append(res.Racks, RackRow{Code: code, SideCard: sideCard})
		}
	}
	return nil
}

// parseCellRows разбирает лист cells. knownRacks — стеллажи листа racks: ссылка на стеллаж
// вне листа — опечатка (rack_labels останавливался на ней), строка уходит в отчёт. Без листа
// racks стеллаж берётся из колонки как есть и заводится при загрузке.
func parseCellRows(f *excelize.File, sheet string, res *CellsParseResult, knownRacks map[string]bool) error {
	rows, err := f.GetRows(sheet)
	if err != nil {
		return fmt.Errorf("чтение листа %q: %w", sheet, err)
	}
	if len(rows) == 0 {
		return fmt.Errorf("лист %q пуст", sheet)
	}
	cols, err := sheetHeader(rows[0], sheet, ColCellID, ColSize)
	if err != nil {
		return err
	}
	seen := map[string]bool{}
	for i := 1; i < len(rows); i++ {
		row := rows[i]
		address := colValue(row, cols, ColCellID)
		rack := colValue(row, cols, ColRackID)
		size := strings.ToLower(colValue(row, cols, ColSize))
		arrow := strings.ToLower(colValue(row, cols, ColArrow))
		barcodeRaw := colValue(row, cols, ColBarcode)
		if address == "" && rack == "" && size == "" && arrow == "" && barcodeRaw == "" {
			continue // пустая строка
		}
		bad := func(msg string) { res.Errors = append(res.Errors, RowError{Row: i + 1, Message: msg}) }
		if address == "" {
			bad("ячейка без адреса — пропущена")
			continue
		}
		if seen[address] {
			bad(fmt.Sprintf("ячейка %q повторяется — пропущена", address))
			continue
		}
		if size != SizeLarge && size != SizeSmall {
			bad(fmt.Sprintf("ячейка %q: size %q — ожидается large или small; пропущена", address, size))
			continue
		}
		if arrow == "" {
			arrow = ArrowNone
		}
		if arrow == ArrowUp {
			bad(fmt.Sprintf("ячейка %q: стрелки вверх в WMS нет — пропущена", address))
			continue
		}
		if arrow != ArrowNone && arrow != ArrowDown {
			bad(fmt.Sprintf("ячейка %q: arrow %q — ожидается none или down; пропущена", address, arrow))
			continue
		}
		barcode, ok := parseBool(barcodeRaw)
		if !ok {
			bad(fmt.Sprintf("ячейка %q: не распознан barcode %q — пропущена", address, barcodeRaw))
			continue
		}
		if rack != "" && res.HasRacksSheet && !knownRacks[rack] {
			bad(fmt.Sprintf("ячейка %q: стеллажа %q нет на листе racks — пропущена", address, rack))
			continue
		}
		seen[address] = true
		res.Cells = append(res.Cells, CellRow{
			Address: address, RackCode: rack,
			LabelSmall: size == SizeSmall, IsFloor: arrow == ArrowDown, LabelBarcode: barcode,
		})
	}
	return nil
}

// findSheet ищет лист по имени без учёта регистра; пусто — листа нет.
func findSheet(f *excelize.File, name string) string {
	for _, s := range f.GetSheetList() {
		if strings.EqualFold(strings.TrimSpace(s), name) {
			return s
		}
	}
	return ""
}

// sheetHeader строит карту «нормализованное имя колонки → индекс» листа и проверяет обязательные колонки.
func sheetHeader(header []string, sheet string, required ...string) (map[string]int, error) {
	cols := map[string]int{}
	for idx, h := range header {
		if n := norm(h); n != "" {
			cols[n] = idx
		}
	}
	for _, req := range required {
		if _, ok := cols[req]; !ok {
			return nil, fmt.Errorf("на листе %q нет обязательной колонки %q (найдено: %s)", sheet, req, strings.Join(keys(cols), ", "))
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

// parseBool разбирает булеву колонку по словарю rack_labels (config.yaml → booleans). Пусто —
// false. ok=false для нераспознанного значения: такую строку отправляем в отчёт, а не тихо
// считаем false.
func parseBool(s string) (val bool, ok bool) {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "", "false", "ложь", "нет", "no", "0", "n", "-":
		return false, true
	case "true", "истина", "да", "yes", "1", "y", "+":
		return true, true
	default:
		return false, false
	}
}
