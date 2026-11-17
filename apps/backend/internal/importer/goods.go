// Package importer - разбор файлов-выгрузок 1С (.xls) в структуры для загрузки в БД.
// Пока - номенклатура (goods): парсер иерархии групп + товаров.
package importer

import (
	"fmt"
	"io"
	"math"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/extrame/xls"
)

// mangledDateCode - «Код», испорченный extrame/xls: числовую ячейку с пользовательским
// числовым форматом (formatNo >= 164) библиотека принимает за дату и печатает RFC3339
// (напр. код 12246 → «1933-07-11T00:00:00Z», см. XfRk.String в extrame/xls). Ловим ровно
// этот вид, чтобы не трогать нормальные коды.
var mangledDateCode = regexp.MustCompile(`^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$`)

// excelEpoch - база системы дат 1900 (Excel/1С на Windows): serial 1 = 1899-12-31, т.е. день 0 =
// 1899-12-30. От неё же считает timeFromExcelTime в extrame/xls, поэтому обратное преобразование корректно.
var excelEpoch = time.Date(1899, 12, 30, 0, 0, 0, 0, time.UTC)

// demangleCode восстанавливает исходный числовой «Код», если extrame/xls отдал его датой
// (см. mangledDateCode): обратное преобразование даты → Excel-serial (число дней от 1899-12-30).
// Так ключ апсерта остаётся стабильным и совпадает с реальным кодом 1С. Иначе - строка как есть.
// ⚠ Хак завязан на поведение extrame/xls; срабатывает только на точный RFC3339-формат.
func demangleCode(s string) string {
	if !mangledDateCode.MatchString(s) {
		return s
	}
	t, err := time.Parse(time.RFC3339, s)
	if err != nil {
		return s
	}
	serial := int64(math.Round(t.Sub(excelEpoch).Hours() / 24))
	return strconv.FormatInt(serial, 10)
}

// GroupNode - узел пути групп номенклатуры (из строки-раздела файла).
type GroupNode struct {
	Code string // «Код» группы из 1С
	Name string
}

// GoodRow - распарсенный товар с путём групп от корня до его непосредственной группы.
type GoodRow struct {
	Code      string      // «Код» товара из 1С - ключ апсерта
	Name      string      // «Наименование»
	FullName  string      // «Полное наименование»
	UOM       string      // «Ед.» (единица измерения)
	Supplier  string      // «Поставщик» (строкой; дедуп на загрузке)
	GroupPath []GroupNode // путь групп сверху вниз (последняя - группа товара)
}

// RowError - строка файла, которую не удалось принять, с причиной (попадает в отчёт импорта).
type RowError struct {
	Row     int    `json:"row"` // номер строки в файле (1-based, как в Excel)
	Message string `json:"message"`
}

// ParseResult - итог парсинга: принятые товары и отклонённые строки.
type ParseResult struct {
	Goods  []GoodRow
	Errors []RowError
}

// Имена колонок (нормализованные: нижний регистр, обрезаны пробелы). Маппинг по заголовку -
// устойчив к порядку колонок и к лишним колонкам в выгрузке.
const (
	colCode     = "код"
	colName     = "наименование"
	colFullName = "полное наименование"
	colUOM      = "ед."
	colSupplier = "поставщик"
)

// ParseGoods читает выгрузку номенклатуры 1С (.xls) и раскладывает строки в товары с путём групп.
//
// Правило: строка-раздел (группа) = «Полное наименование» пусто (заполнены только Код+Наименование);
// строка-товар = «Полное наименование» заполнено. Иерархия линейная (одна ветка на файл):
// каждый раздел углубляет путь, товар цепляется к самой глубокой группе текущего пути.
func ParseGoods(r io.ReadSeeker) (*ParseResult, error) {
	wb, err := xls.OpenReader(r, "utf-8")
	if err != nil {
		return nil, fmt.Errorf("открыть xls: %w", err)
	}
	sh := wb.GetSheet(0)
	if sh == nil {
		return nil, fmt.Errorf("в файле нет листа")
	}

	// 1. Заголовок (строка 0) → индексы колонок по имени.
	cols, err := headerIndex(sh.Row(0))
	if err != nil {
		return nil, err
	}

	res := &ParseResult{}
	var path []GroupNode

	for i := 1; i <= int(sh.MaxRow); i++ {
		row := sh.Row(i)
		if row == nil {
			continue
		}
		// «Код» - восстанавливаем, если extrame/xls испортил его в дату (числовой формат ячейки).
		code := demangleCode(cellAt(row, cols, colCode))
		name := cellAt(row, cols, colName)
		full := cellAt(row, cols, colFullName)
		uom := cellAt(row, cols, colUOM)
		supplier := cellAt(row, cols, colSupplier)

		if code == "" && name == "" && full == "" {
			continue // пустая строка
		}

		// Строка-раздел: нет «Полного наименования» → группа, углубляем путь.
		if full == "" {
			if code == "" || name == "" {
				res.Errors = append(res.Errors, RowError{Row: i + 1, Message: "раздел без Кода или Наименования - пропущен"})
				continue
			}
			path = append(path, GroupNode{Code: code, Name: name})
			continue
		}

		// Строка-товар. Без Кода апсерт невозможен → в отчёт, пропуск.
		if code == "" {
			res.Errors = append(res.Errors, RowError{Row: i + 1, Message: fmt.Sprintf("товар без Кода (%q) - пропущен", name)})
			continue
		}
		res.Goods = append(res.Goods, GoodRow{
			Code:      code,
			Name:      name,
			FullName:  full,
			UOM:       uom,
			Supplier:  supplier,
			GroupPath: append([]GroupNode(nil), path...), // копия текущего пути (не разделяем срез)
		})
	}
	return res, nil
}

// headerIndex строит карту «нормализованное имя колонки → индекс» и проверяет обязательные колонки.
func headerIndex(row *xls.Row) (map[string]int, error) {
	if row == nil {
		return nil, fmt.Errorf("нет строки заголовка")
	}
	cols := map[string]int{}
	for c := 0; c < row.LastCol(); c++ {
		if h := norm(row.Col(c)); h != "" {
			cols[h] = c
		}
	}
	for _, req := range []string{colCode, colName, colFullName, colUOM, colSupplier} {
		if _, ok := cols[req]; !ok {
			return nil, fmt.Errorf("в заголовке файла нет обязательной колонки %q (найдено: %s)", req, strings.Join(keys(cols), ", "))
		}
	}
	return cols, nil
}

// cellAt возвращает очищенное и обрезанное значение ячейки по имени колонки (пусто, если колонки нет).
func cellAt(row *xls.Row, cols map[string]int, colName string) string {
	idx, ok := cols[colName]
	if !ok {
		return ""
	}
	return strings.TrimSpace(stripControl(row.Col(idx)))
}

func norm(s string) string { return strings.ToLower(strings.TrimSpace(stripControl(s))) }

// stripControl удаляет управляющие байты (C0 и DEL), включая NUL (0x00). Зачем: extrame/xls иногда
// оставляет в строке 0x00 - остаток UTF-16-паддинга исходного .xls; Postgres не принимает 0x00 в
// колонке text (SQLSTATE 22021), из-за чего падал импорт. В значениях номенклатуры управляющих
// символов быть не должно, поэтому выкидываем их все (табы/переводы строк тоже).
func stripControl(s string) string {
	if !strings.ContainsFunc(s, isControl) {
		return s // быстрый путь: чистить нечего
	}
	return strings.Map(func(r rune) rune {
		if isControl(r) {
			return -1 // выбросить руну
		}
		return r
	}, s)
}

func isControl(r rune) bool { return r < 0x20 || r == 0x7f }

func keys(m map[string]int) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	return out
}
