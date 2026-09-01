package service

import (
	"reflect"
	"testing"
)

// Разбиение поисковой строки на слова: нормализация под сравнение с полем в SQL
// (нижний регистр, «ё»→«е») и экранирование метасимволов LIKE.
func TestSearchWords(t *testing.T) {
	cases := []struct {
		name  string
		query string
		want  []string
	}{
		{"пусто", "", []string{}},
		{"только пробелы", "   \t ", []string{}},
		{"одно слово", "Бекон", []string{"бекон"}},
		{"несколько слов, лишние пробелы", "  фома   бекон ", []string{"фома", "бекон"}},
		{"ё приводится к е с обеих сторон", "Берёза", []string{"береза"}},
		{"метасимволы LIKE экранируются", "50% s_1", []string{`50\%`, `s\_1`}},
		{"обратный слэш экранируется", `a\b`, []string{`a\\b`}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := searchWords(c.query); !reflect.DeepEqual(got, c.want) {
				t.Fatalf("searchWords(%q) = %#v, ожидали %#v", c.query, got, c.want)
			}
		})
	}
}

// Число слов ограничено: длинный запрос не превращается в простыню LIKE-условий.
func TestSearchWords_capped(t *testing.T) {
	query := "a b c d e f g h i j k l m n"
	if got := len(searchWords(query)); got != maxSearchWords {
		t.Fatalf("слов %d, ожидали потолок %d", got, maxSearchWords)
	}
}
