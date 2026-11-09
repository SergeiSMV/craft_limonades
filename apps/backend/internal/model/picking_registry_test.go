package model

import "testing"

// TestNormalizeGoodCode — оба вида кода из реестра приводятся к одиннадцати цифрам справочника.
func TestNormalizeGoodCode(t *testing.T) {
	cases := []struct {
		raw, want string
		ok        bool
	}{
		{"00000016147", "00000016147", true},
		{"00-00001101", "00000001101", true},
		{"16147", "00000016147", true},
		{" 00-00001101 ", "00000001101", true},
		{"", "", false},
		{"АБВ", "", false},
		{"123456789012", "", false}, // длиннее справочника
	}
	for _, c := range cases {
		got, ok := NormalizeGoodCode(c.raw)
		if got != c.want || ok != c.ok {
			t.Errorf("NormalizeGoodCode(%q) = %q, %v; ждали %q, %v", c.raw, got, ok, c.want, c.ok)
		}
	}
}

// TestCellAddressKey — адреса с латинскими и кириллическими двойниками совпадают, разные
// стеллажи — нет.
func TestCellAddressKey(t *testing.T) {
	same := [][2]string{
		{"C-1-1-1", "С-1-1-1"}, // латинская C и кириллическая С
		{"B-2-1-3", "В-2-1-3"},
		{"D-H-П", "D-Н-П"}, // латиница с кириллицей у 1С
		{"M1-1-1-1", "М1-1-1-1"},
		{" с-н-п ", "С-Н-П"}, // регистр и пробелы
		{"ПРИЁМКА", "ПРИЁМКА"},
	}
	for _, p := range same {
		if CellAddressKey(p[0]) != CellAddressKey(p[1]) {
			t.Errorf("%q и %q должны совпасть: %q / %q", p[0], p[1], CellAddressKey(p[0]), CellAddressKey(p[1]))
		}
	}
	differ := [][2]string{{"D-1-1-1", "Д-1-1-1"}, {"А-1-1-1", "С-1-1-1"}, {"C-1-1-1", "C-1-1-2"}}
	for _, p := range differ {
		if CellAddressKey(p[0]) == CellAddressKey(p[1]) {
			t.Errorf("%q и %q не должны совпасть", p[0], p[1])
		}
	}
}
