package importer

import (
	"bytes"
	"os"
	"strings"
	"testing"
	"time"
)

// registrySamplePath - образец «Реестра», отданный 1С вместе с ТЗ.
const registrySamplePath = "testdata/registry_sample.xlsx"

// registryHeader - заголовок реестра в порядке 1С.
var registryHeader = []any{"Номер накладной", "Дата накладной", "Номер заказа", "Дата заказа", "Статус",
	"Направление", "Клиент", "Адрес", "Код товара", "Товар", "Партия", "Количество", "Ячейка", "Вес, кг"}

// regRow - строка реестра; даты - числом Excel, как их отдаёт 1С (46325 = 30.10.2026).
func regRow(invoice, order, code, batch, qty, cell string) []any {
	return []any{invoice, 46325, order, 46325, "Отработан", "ЛИПЕЦК", "ИП Иванов", "Липецк, ул. Мира, 1",
		code, "Товар " + code, batch, qty, cell, 1.5}
}

func date(y int, m time.Month, d int) time.Time { return time.Date(y, m, d, 0, 0, 0, 0, time.UTC) }

// TestParseRegistry_sample - образец 1С: 11 строк, две накладные, код вида «00-00001101»,
// даты текстом формата «10.10.2026» в ячейках-датах, пустые ячейки.
func TestParseRegistry_sample(t *testing.T) {
	f, err := os.Open(registrySamplePath)
	if err != nil {
		t.Fatalf("открыть образец: %v", err)
	}
	defer func() { _ = f.Close() }()
	res, err := ParseRegistry(f)
	if err != nil {
		t.Fatalf("ParseRegistry: %v", err)
	}
	if len(res.Errors) != 0 || len(res.Rows) != 11 {
		t.Fatalf("строк %d (ждали 11), ошибок %d: %+v", len(res.Rows), len(res.Errors), res.Errors)
	}
	if !res.Date.Equal(date(2026, 10, 10)) {
		t.Errorf("дата файла %v, ждали 10.10.2026", res.Date)
	}
	r := res.Rows[0]
	if r.Row != 2 || r.InvoiceNumber != "67772" || r.OrderNumber != "12321" ||
		r.GoodCode != "00000001101" || r.GoodCodeRaw != "00-00001101" || r.Qty != 2 || r.CellAddress != "" {
		t.Errorf("первая строка: %+v", r)
	}
	if r.Batch == nil || !r.Batch.Equal(date(2026, 8, 21)) {
		t.Errorf("партия первой строки %v, ждали 21.08.2026", r.Batch)
	}
	if r.OrderDate == nil || r.Client == "" || r.Address == "" || r.Direction != "Талдом" {
		t.Errorf("шапка заказа не прочитана: %+v", r)
	}
}

// TestParseRegistry_rejectedRows - плохие строки уходят в отчёт с причиной, хорошие принимаются;
// пустая строка пропускается молча.
func TestParseRegistry_rejectedRows(t *testing.T) {
	bad := regRow("20001", "15001", "00000016147", "", "2", "")
	bad[1] = "вчера" // дата накладной не дата
	data := buildXLSXSheet(t, "Реестр", [][]any{
		registryHeader,
		regRow("20001", "15001", "00000016147", "46276", "2", "С-1-1-1"), // принята
		regRow("20001", "15001", "00-00001101", "", "3.0", ""),           // принята: «3.0», без партии
		regRow("", "15001", "00000016147", "", "1", ""),                  // без накладной
		regRow("20001", "", "00000016147", "", "1", ""),                  // без заказа
		regRow("20001", "15001", "", "", "1", ""),                        // без кода
		regRow("20001", "15001", "АБВ", "", "1", ""),                     // код без цифр
		regRow("20001", "15001", "00000016147", "", "1.5", ""),           // дробное количество
		regRow("20001", "15001", "00000016147", "", "0", ""),             // ноль
		regRow("20001", "15001", "00000016147", "скоро", "1", ""),        // партия не дата
		bad,
		regRow("20002", "15001", "00000016147", "", "1", ""), // заказ в другой накладной
		{"", "", "", "", "", "", "", "", "", "", "", "", "", ""},
		regRow("20002", "15002", "16147", "", "4", "D-Н-П"), // принята: код без нулей
	})
	res, err := ParseRegistry(bytes.NewReader(data))
	if err != nil {
		t.Fatalf("ParseRegistry: %v", err)
	}
	if len(res.Rows) != 3 {
		t.Fatalf("принято %d строк (ждали 3): %+v", len(res.Rows), res.Rows)
	}
	if res.Rows[1].Qty != 3 || res.Rows[1].Batch != nil || res.Rows[1].GoodCode != "00000001101" {
		t.Errorf("вторая строка: %+v", res.Rows[1])
	}
	if res.Rows[0].Batch == nil || !res.Rows[0].Batch.Equal(date(2026, 9, 11)) {
		t.Errorf("партия 46276 = 11.09.2026, получено %v", res.Rows[0].Batch)
	}
	if res.Rows[2].GoodCode != "00000016147" || res.Rows[2].CellAddress != "D-Н-П" || res.Rows[2].Row != 14 {
		t.Errorf("последняя строка: %+v", res.Rows[2])
	}
	if !res.Date.Equal(date(2026, 10, 30)) {
		t.Errorf("дата файла %v, ждали 30.10.2026", res.Date)
	}
	wants := []string{"номера накладной", "номера заказа", "кода товара", "АБВ", "1.5", "\"0\"", "скоро", "вчера", "уже есть в накладной 20001"}
	if len(res.Errors) != len(wants) {
		t.Fatalf("отклонено %d строк (ждали %d): %+v", len(res.Errors), len(wants), res.Errors)
	}
	for i, sub := range wants {
		if !strings.Contains(res.Errors[i].Message, sub) {
			t.Errorf("ошибка %d: %q, ждали с %q", i, res.Errors[i].Message, sub)
		}
	}
}

// TestParseRegistry_fileErrors - файл отклоняется целиком: две даты, нет колонки, нет строк,
// не тот лист.
func TestParseRegistry_fileErrors(t *testing.T) {
	twoDates := regRow("20002", "15002", "00000016147", "", "1", "")
	twoDates[1] = 46326
	noCell := make([]any, 0, len(registryHeader))
	for _, h := range registryHeader {
		if h != "Ячейка" {
			noCell = append(noCell, h)
		}
	}
	other := buildXLSXSheet(t, "Реестр", [][]any{registryHeader})
	cases := []struct {
		name string
		data []byte
		want string
	}{
		{"две даты", buildXLSXSheet(t, "Реестр", [][]any{registryHeader,
			regRow("20001", "15001", "00000016147", "", "1", ""), twoDates}), "30.10.2026, 31.10.2026"},
		{"нет колонки", buildXLSXSheet(t, "Реестр", [][]any{noCell}), "ячейка"},
		{"нет строк", other, "нет ни одной принятой строки"},
		{"не xlsx", []byte("не файл"), "открыть xlsx"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			_, err := ParseRegistry(bytes.NewReader(c.data))
			if err == nil || !strings.Contains(err.Error(), c.want) {
				t.Fatalf("ошибка %v, ждали с %q", err, c.want)
			}
		})
	}
}

// TestParseRegistry_anySheetName - лист с другим именем принимается, если он в книге один.
func TestParseRegistry_anySheetName(t *testing.T) {
	data := buildXLSXSheet(t, "Лист1", [][]any{registryHeader, regRow("20001", "15001", "00000016147", "", "1", "")})
	res, err := ParseRegistry(bytes.NewReader(data))
	if err != nil || len(res.Rows) != 1 {
		t.Fatalf("ParseRegistry: %v, строк %v", err, res)
	}
}
