package importer

import (
	"os"
	"testing"
)

// TestParseGoods_realSample - парсинг реальной выгрузки 1С (Кальмары.xls в testdata):
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

	// Все товары в этом файле - одна ветка (тот же путь групп).
	for i, gg := range res.Goods {
		if len(gg.GroupPath) != 3 || gg.GroupPath[2].Code != "5046" {
			t.Errorf("товар %d: ожидалась группа 5046 в пути, получено %+v", i, gg.GroupPath)
		}
		if gg.Code == "" {
			t.Errorf("товар %d без кода", i)
		}
	}

	// В образце два разных поставщика (ТОРГМАРКЕТ и Вялкин) - проверим, что оба встречаются.
	suppliers := map[string]bool{}
	for _, gg := range res.Goods {
		suppliers[gg.Supplier] = true
	}
	if len(suppliers) < 2 {
		t.Errorf("ожидалось >=2 разных поставщиков, получено %d: %v", len(suppliers), suppliers)
	}
}

// TestParseGoods_mangledDateCodes - файл, где extrame/xls портит числовой «Код» в дату
// (Каскад розлив.xls: у ячеек кода пользовательский числовой формат). Проверяем, что коды
// восстановлены в числа (demangleCode), а не остались RFC3339-датами.
func TestParseGoods_mangledDateCodes(t *testing.T) {
	f, err := os.Open("testdata/nomenclature_dates_sample.xls")
	if err != nil {
		t.Fatalf("открыть образец: %v", err)
	}
	defer func() { _ = f.Close() }()

	res, err := ParseGoods(f)
	if err != nil {
		t.Fatalf("ParseGoods: %v", err)
	}
	if len(res.Goods) == 0 {
		t.Fatal("ожидались товары, получено 0")
	}

	// Все коды товаров и групп пути - числовые (не даты).
	numeric := func(s string) bool {
		for _, r := range s {
			if r < '0' || r > '9' {
				return false
			}
		}
		return s != ""
	}
	for _, g := range res.Goods {
		if !numeric(g.Code) {
			t.Errorf("код товара %q не число (де-манглинг не сработал): %q", g.Name, g.Code)
		}
		for _, node := range g.GroupPath {
			if !numeric(node.Code) {
				t.Errorf("код группы %q не число: %q", node.Name, node.Code)
			}
		}
	}

	// Точечно: товар «Яблочный сад …» - код-дата 1933-07-11 → Excel-serial 12246.
	var found bool
	for _, g := range res.Goods {
		if g.Code == "12246" {
			found = true
			break
		}
	}
	if !found {
		t.Errorf("ожидался товар с восстановленным кодом 12246 (из 1933-07-11)")
	}
}

// TestDemangleCode - обратное преобразование испорченной даты в Excel-serial; обычные коды не трогаются.
func TestDemangleCode(t *testing.T) {
	cases := map[string]string{
		"1933-07-11T00:00:00Z": "12246", // дата → serial
		"1899-12-31T00:00:00Z": "1",     // граница системы 1900
		"16121":                "16121", // обычный код - как есть
		"":                     "",
		"5046":                 "5046",
	}
	for in, want := range cases {
		if got := demangleCode(in); got != want {
			t.Errorf("demangleCode(%q) = %q, ожидалось %q", in, got, want)
		}
	}
}

// stripControl должен убирать управляющие байты, включая NUL (0x00), который валил импорт
// (Postgres не принимает 0x00 в text). Обычный текст - без изменений.
func TestStripControl(t *testing.T) {
	cases := map[string]string{
		"Мясные\x00 снеки": "Мясные снеки",   // NUL внутри - вырезан
		"код14900\x00":     "код14900",       // хвостовой NUL
		"a\x01b\x1fc\x7fd": "abcd",           // прочие C0 + DEL
		"Кальмар кольца":   "Кальмар кольца", // чистый текст не трогаем
		"с\tтаб\nперенос":  "стабперенос",    // табы/переводы строк тоже убираем
		"":                 "",
	}
	for in, want := range cases {
		if got := stripControl(in); got != want {
			t.Errorf("stripControl(%q) = %q, ожидалось %q", in, got, want)
		}
	}
}
