package importer

import (
	"fmt"
	"io"
	"math"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/xuri/excelize/v2"

	"craftwms/internal/model"
)

// Лист и колонки «Реестра» заявок на сборку из 1С (docs/picking.md, образец -
// importer/testdata/registry_sample.xlsx). Имена нормализуются (регистр, пробелы), порядок колонок
// не важен. «Статус» и «Вес, кг» не читаются: у сборки свои статусы WMS, вес отложен.
const (
	SheetRegistry = "реестр"

	colRegInvoice     = "номер накладной"
	colRegInvoiceDate = "дата накладной"
	colRegOrder       = "номер заказа"
	colRegOrderDate   = "дата заказа"
	colRegDirection   = "направление"
	colRegClient      = "клиент"
	colRegAddress     = "адрес"
	colRegGoodCode    = "код товара"
	colRegGoodName    = "товар"
	colRegBatch       = "партия"
	colRegQty         = "количество"
	colRegCell        = "ячейка"
)

// registryRequired - колонки, без которых файл не принимается целиком: формат согласован с 1С,
// пропавшая колонка значит не тот файл, а не пустые значения.
var registryRequired = []string{
	colRegInvoice, colRegInvoiceDate, colRegOrder, colRegOrderDate, colRegDirection, colRegClient,
	colRegAddress, colRegGoodCode, colRegGoodName, colRegBatch, colRegQty, colRegCell,
}

// RegistryRow - строка реестра: позиция заказа с шапкой его документа.
type RegistryRow struct {
	Row           int        // номер строки в файле (1-based, как в Excel)
	InvoiceNumber string     // номер накладной - ключ документа вместе с заказом
	InvoiceDate   time.Time  // дата накладной = дата сборки, по ней сверяются повторные загрузки
	OrderNumber   string     // номер заказа - единица задания сборки
	OrderDate     *time.Time // дата заказа - для показа; nil, если пусто
	Direction     string
	Client        string
	Address       string
	GoodCode      string     // код в формате справочника (model.NormalizeGoodCode)
	GoodCodeRaw   string     // код как в файле - для показа нераспознанного
	GoodName      string     // наименование из 1С - для показа, сопоставление по коду
	Batch         *time.Time // партия = дата производства; nil - строка без партии (FEFO)
	Qty           int        // план строки, > 0
	CellAddress   string     // ячейка из 1С как есть; пусто - без ячейки (ячейка WMS)
}

// RegistryParseResult - итог разбора реестра: дата сборки файла, принятые строки и отклонённые.
type RegistryParseResult struct {
	Date   time.Time // дата накладных файла (в одном файле одна дата)
	Rows   []RegistryRow
	Errors []RowError
}

// ParseRegistry читает «Реестр» 1С (.xlsx) в строки позиций заказов.
//
// Что: строка файла → RegistryRow с приведённым кодом товара и датами. Зачем: из строк строятся
// документы «накладная + заказ» и задания сборки (P9-02…P9-03), повторная загрузка сверяется с
// прошлой той же даты. Как: лист «Реестр» (или единственный лист файла), значения читаются
// сырыми - даты приходят числом Excel, а не текстом формата ячейки, который у 1С меняется от
// выгрузки к выгрузке («10-30-26», «10.10.2026»). Проблемная строка не валит файл, а уходит в
// отчёт с причиной. Файл отклоняется целиком, если нет нужной колонки, нет ни одной строки или
// в нём несколько дат накладных: повторная загрузка сравнивается с прошлой загрузкой той же даты,
// и файл на две даты сломал бы сверку обеих.
func ParseRegistry(r io.Reader) (*RegistryParseResult, error) {
	f, err := excelize.OpenReader(r)
	if err != nil {
		return nil, fmt.Errorf("открыть xlsx: %w", err)
	}
	defer func() { _ = f.Close() }()

	sheet := findSheet(f, SheetRegistry)
	if sheet == "" {
		if list := f.GetSheetList(); len(list) == 1 {
			sheet = list[0]
		} else {
			return nil, fmt.Errorf("в файле нет листа «Реестр» (найдено: %s)", strings.Join(list, ", "))
		}
	}
	rows, err := f.GetRows(sheet, excelize.Options{RawCellValue: true})
	if err != nil {
		return nil, fmt.Errorf("чтение листа %q: %w", sheet, err)
	}
	if len(rows) == 0 {
		return nil, fmt.Errorf("лист %q пуст", sheet)
	}
	cols, err := sheetHeader(rows[0], sheet, registryRequired...)
	if err != nil {
		return nil, err
	}

	res := &RegistryParseResult{}
	orderInvoice := map[string]string{} // заказ → накладная первой его строки
	dates := map[time.Time]bool{}
	for i := 1; i < len(rows); i++ {
		row, rowErr := parseRegistryRow(rows[i], cols, i+1)
		if rowErr != "" {
			res.Errors = append(res.Errors, RowError{Row: i + 1, Message: rowErr})
			continue
		}
		if row == nil {
			continue // пустая строка
		}
		// Заказ всегда в одной накладной (docs/picking.md): заказ под двумя накладными - ошибка
		// выгрузки, такую строку не угадываем.
		if inv, seen := orderInvoice[row.OrderNumber]; seen && inv != row.InvoiceNumber {
			res.Errors = append(res.Errors, RowError{Row: i + 1, Message: fmt.Sprintf(
				"заказ %s уже есть в накладной %s, а здесь - в накладной %s", row.OrderNumber, inv, row.InvoiceNumber)})
			continue
		}
		orderInvoice[row.OrderNumber] = row.InvoiceNumber
		dates[row.InvoiceDate] = true
		res.Rows = append(res.Rows, *row)
	}

	switch len(dates) {
	case 0:
		return nil, fmt.Errorf("в файле нет ни одной принятой строки (%d с ошибками)", len(res.Errors))
	case 1:
		res.Date = res.Rows[0].InvoiceDate
	default:
		list := make([]string, 0, len(dates))
		for d := range dates {
			list = append(list, d.Format("02.01.2006"))
		}
		sort.Strings(list)
		return nil, fmt.Errorf("в файле несколько дат накладных (%s) - нужен реестр за один день", strings.Join(list, ", "))
	}
	return res, nil
}

// parseRegistryRow разбирает одну строку. Возвращает (nil, "") для пустой строки и причину
// отказа для плохой: без номеров документа, даты накладной, кода или с нецелым количеством.
func parseRegistryRow(raw []string, cols map[string]int, rowNum int) (*RegistryRow, string) {
	get := func(col string) string { return strings.TrimSpace(stripControl(colValue(raw, cols, col))) }

	row := RegistryRow{
		Row:           rowNum,
		InvoiceNumber: get(colRegInvoice),
		OrderNumber:   get(colRegOrder),
		Direction:     get(colRegDirection),
		Client:        get(colRegClient),
		Address:       get(colRegAddress),
		GoodCodeRaw:   get(colRegGoodCode),
		GoodName:      get(colRegGoodName),
		CellAddress:   get(colRegCell),
	}
	invoiceDate, batch, orderDate, qty := get(colRegInvoiceDate), get(colRegBatch), get(colRegOrderDate), get(colRegQty)
	if row.InvoiceNumber == "" && row.OrderNumber == "" && row.GoodCodeRaw == "" && qty == "" {
		return nil, ""
	}

	switch {
	case row.InvoiceNumber == "":
		return nil, "нет номера накладной"
	case row.OrderNumber == "":
		return nil, "нет номера заказа"
	case row.GoodCodeRaw == "":
		return nil, "нет кода товара"
	}

	var ok bool
	if row.GoodCode, ok = model.NormalizeGoodCode(row.GoodCodeRaw); !ok {
		return nil, fmt.Sprintf("код товара %q не похож на код справочника", row.GoodCodeRaw)
	}
	d, err := parseRegistryDate(invoiceDate)
	if err != nil || d == nil {
		return nil, fmt.Sprintf("дата накладной %q не распознана", invoiceDate)
	}
	row.InvoiceDate = *d
	if row.OrderDate, err = parseRegistryDate(orderDate); err != nil {
		return nil, fmt.Sprintf("дата заказа %q не распознана", orderDate)
	}
	if row.Batch, err = parseRegistryDate(batch); err != nil {
		return nil, fmt.Sprintf("партия %q не распознана как дата производства", batch)
	}
	if row.Qty, ok = parseRegistryQty(qty); !ok {
		return nil, fmt.Sprintf("количество %q - нужно целое больше нуля", qty)
	}
	return &row, ""
}

// registryDateLayouts - текстовые даты на случай, если 1С выгрузит дату строкой, а не числом.
var registryDateLayouts = []string{"02.01.2006", "2006-01-02", "02.01.06"}

// parseRegistryDate разбирает дату реестра: число Excel (сырое значение ячейки-даты) или текст.
// Пусто - (nil, nil). Время суток отбрасывается: и накладная, и партия - календарные даты.
func parseRegistryDate(s string) (*time.Time, error) {
	if s == "" {
		return nil, nil
	}
	if serial, err := strconv.ParseFloat(s, 64); err == nil {
		t, err := excelize.ExcelDateToTime(serial, false)
		if err != nil {
			return nil, err
		}
		d := time.Date(t.Year(), t.Month(), t.Day(), 0, 0, 0, 0, time.UTC)
		return &d, nil
	}
	for _, layout := range registryDateLayouts {
		if t, err := time.Parse(layout, s); err == nil {
			return &t, nil
		}
	}
	return nil, fmt.Errorf("дата %q не распознана", s)
}

// parseRegistryQty - количество строки: целое > 0. «2» и «2.0» принимаются, «1.5» и «0» - нет:
// сборка штучная, дробный план значит ошибку выгрузки.
func parseRegistryQty(s string) (int, bool) {
	v, err := strconv.ParseFloat(strings.ReplaceAll(s, ",", "."), 64)
	if err != nil || v <= 0 || v != math.Trunc(v) || v > math.MaxInt32 {
		return 0, false
	}
	return int(v), true
}
