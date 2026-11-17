package service

import (
	"bytes"
	"context"
	"errors"
	"reflect"
	"strings"
	"testing"

	"github.com/xuri/excelize/v2"

	"craftwms/internal/model"
)

// fakeRegistryGoods - справочник в памяти; codes - коды последнего запроса.
type fakeRegistryGoods struct {
	goods map[string]model.RegistryGood
	codes []string
	err   error
}

func (f *fakeRegistryGoods) ByCodes(_ context.Context, codes []string) (map[string]model.RegistryGood, error) {
	f.codes = codes
	if f.err != nil {
		return nil, f.err
	}
	out := map[string]model.RegistryGood{}
	for _, c := range codes {
		if g, ok := f.goods[c]; ok {
			out[c] = g
		}
	}
	return out, nil
}

// registryFile собирает «Реестр» за 30.10.2026 (46325 - дата числом Excel) из строк
// {накладная, заказ, клиент, код, количество}.
func registryFile(t *testing.T, rows [][5]string) []byte {
	t.Helper()
	f := excelize.NewFile()
	defer func() { _ = f.Close() }()
	if err := f.SetSheetName("Sheet1", "Реестр"); err != nil {
		t.Fatal(err)
	}
	all := [][]any{{"Номер накладной", "Дата накладной", "Номер заказа", "Дата заказа", "Статус", "Направление",
		"Клиент", "Адрес", "Код товара", "Товар", "Партия", "Количество", "Ячейка", "Вес, кг"}}
	for _, r := range rows {
		all = append(all, []any{r[0], 46325, r[1], 46325, "Отработан", "ВОРОНЕЖ", r[2], "Воронеж", r[3], "Товар", "", r[4], "", 0})
	}
	for i, row := range all {
		cell, _ := excelize.CoordinatesToCellName(1, i+1)
		if err := f.SetSheetRow("Реестр", cell, &row); err != nil {
			t.Fatal(err)
		}
	}
	var buf bytes.Buffer
	if err := f.Write(&buf); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

// TestPickingRegistryParse_groupsOrders - накладная из двух заказов даёт два заказа, строки
// заказа идут в порядке файла, нераспознанный код помечает заказ, справочник читается одним
// запросом без повторов кодов.
func TestPickingRegistryParse_groupsOrders(t *testing.T) {
	repo := &fakeRegistryGoods{goods: map[string]model.RegistryGood{
		"00000016147": {ID: "g1", Code: "00000016147", Name: "Козел", CZMarked: true},
		"00000001101": {ID: "g2", Code: "00000001101", Name: "Сыр"},
	}}
	data := registryFile(t, [][5]string{
		{"20001", "15001", "ИП Иванов", "00000016147", "2"},
		{"20001", "15002", "ИП Иванов", "00-00001101", "1"},
		{"20001", "15001", "ИП Иванов", "00000099999", "3"}, // нет в справочнике
		{"20002", "15003", "ИП Петров", "16147", "5"},
	})
	got, err := NewPickingRegistryService(repo).Parse(context.Background(), bytes.NewReader(data))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if !reflect.DeepEqual(repo.codes, []string{"00000016147", "00000001101", "00000099999"}) {
		t.Errorf("коды запроса %v", repo.codes)
	}
	if len(got.Orders) != 3 {
		t.Fatalf("заказов %d (ждали 3): %+v", len(got.Orders), got.Orders)
	}
	o1, o2, o3 := got.Orders[0], got.Orders[1], got.Orders[2]
	if o1.OrderNumber != "15001" || o1.InvoiceNumber != "20001" || len(o1.Lines) != 2 || !o1.HasUnknown {
		t.Errorf("заказ 15001: %+v", o1)
	}
	if o1.Lines[0].Good == nil || !o1.Lines[0].Good.CZMarked || o1.Lines[1].Good != nil || o1.Lines[1].Qty != 3 {
		t.Errorf("строки заказа 15001: %+v", o1.Lines)
	}
	if o2.OrderNumber != "15002" || o2.InvoiceNumber != "20001" || o2.HasUnknown || o2.Lines[0].Good.ID != "g2" {
		t.Errorf("заказ 15002: %+v", o2)
	}
	if o3.Client != "ИП Петров" || o3.Lines[0].Good.ID != "g1" {
		t.Errorf("заказ 15003: %+v", o3)
	}
	if !reflect.DeepEqual(got.UnknownCodes, []string{"00000099999"}) {
		t.Errorf("нераспознанные коды %v", got.UnknownCodes)
	}
}

// TestPickingRegistryParse_errors - ошибка файла и справочника доходит до вызывающего.
func TestPickingRegistryParse_errors(t *testing.T) {
	svc := NewPickingRegistryService(&fakeRegistryGoods{err: errors.New("база недоступна")})
	if _, err := svc.Parse(context.Background(), bytes.NewReader([]byte("не файл"))); err == nil {
		t.Error("ждали ошибку разбора файла")
	}
	data := registryFile(t, [][5]string{{"20001", "15001", "ИП", "00000016147", "1"}})
	if _, err := svc.Parse(context.Background(), bytes.NewReader(data)); err == nil || !strings.Contains(err.Error(), "база недоступна") {
		t.Errorf("ошибка справочника: %v", err)
	}
}
