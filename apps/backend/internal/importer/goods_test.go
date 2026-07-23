package importer

import (
	"os"
	"testing"
)

// TestParseGoods_realSample — парсинг реальной выгрузки 1С (Кальмары.xls в testdata):
// правильно отделены разделы от товаров, собран путь групп, кириллица цела.
func TestParseGoods_realSample(t *testing.T) {
	f, err := os.Open("testdata/nomenclature_sample.xls")
	if err != nil {
		t.Fatalf("открыть образец: %v", err)
	}
	defer func() { _ = f.Close() }()

	res, err := ParseGoods(f)
	if err != nil {
		t.Fatalf("ParseGoods: %v", err)
	}
	if len(res.Errors) != 0 {
		t.Fatalf("ожидалось 0 ошибок строк, получено %d: %+v", len(res.Errors), res.Errors)
	}
	if len(res.Goods) != 15 {
		t.Fatalf("ожидалось 15 товаров, получено %d", len(res.Goods))
	}

	// Первый товар: поля и путь групп (3 уровня: L1 → L2 → L3).
	g := res.Goods[0]
	if g.Code != "16121" {
		t.Errorf("code первого товара: ожидалось 16121, получено %q", g.Code)
	}
	if g.UOM != "шт" {
		t.Errorf("uom: ожидалось 'шт', получено %q", g.UOM)
	}
	if g.Supplier != `ООО "ТОРГМАРКЕТ"` {
		t.Errorf("supplier: получено %q", g.Supplier)
	}
	if g.FullName == "" || g.Name == "" {
		t.Errorf("имя/полное имя не должны быть пустыми: name=%q full=%q", g.Name, g.FullName)
	}
	wantPath := []GroupNode{
		{Code: "1", Name: "-ТОВАРЫ/ ОСНОВНАЯ НОМЕНКЛАТУРНАЯ ГРУППА"},
		{Code: "2331", Name: "4/ Матрица РЫБА-СНЭКИ"},
		{Code: "5046", Name: "КАЛЬМАРОВАЯ ГРУППА"},
	}
	if len(g.GroupPath) != len(wantPath) {
		t.Fatalf("глубина пути групп: ожидалось %d, получено %d (%+v)", len(wantPath), len(g.GroupPath), g.GroupPath)
	}
	for i, want := range wantPath {
		if g.GroupPath[i] != want {
			t.Errorf("узел пути [%d]: ожидалось %+v, получено %+v", i, want, g.GroupPath[i])
		}
	}

	// Все товары в этом файле — одна ветка (тот же путь групп).
	for i, gg := range res.Goods {
		if len(gg.GroupPath) != 3 || gg.GroupPath[2].Code != "5046" {
			t.Errorf("товар %d: ожидалась группа 5046 в пути, получено %+v", i, gg.GroupPath)
		}
		if gg.Code == "" {
			t.Errorf("товар %d без кода", i)
		}
	}

	// В образце два разных поставщика (ТОРГМАРКЕТ и Вялкин) — проверим, что оба встречаются.
	suppliers := map[string]bool{}
	for _, gg := range res.Goods {
		suppliers[gg.Supplier] = true
	}
	if len(suppliers) < 2 {
		t.Errorf("ожидалось >=2 разных поставщиков, получено %d: %v", len(suppliers), suppliers)
	}
}
