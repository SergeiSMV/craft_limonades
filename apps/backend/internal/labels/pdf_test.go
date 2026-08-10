package labels

import (
	"bytes"
	"fmt"
	"testing"

	"craftwms/internal/model"
)

// Render — чистая функция (без БД): проверяем валидность PDF и устойчивость к многостраничности.
func TestRender_emptyValidPDF(t *testing.T) {
	b, err := Render(nil)
	if err != nil {
		t.Fatalf("Render(nil): %v", err)
	}
	if !bytes.HasPrefix(b, []byte("%PDF")) {
		t.Fatalf("ожидался PDF (%%PDF-заголовок), получено %q", head(b))
	}
}

func TestRender_multiPage(t *testing.T) {
	// 10 ячеек > 8/лист → 2 страницы; часть напольные (стрелка). Не должно падать.
	cells := make([]model.CellLabel, 0, 10)
	for i := 1; i <= 10; i++ {
		cells = append(cells, model.CellLabel{Address: fmt.Sprintf("M1-1-1-%d", i), IsFloor: i <= 4})
	}
	b, err := Render(cells)
	if err != nil {
		t.Fatalf("Render(10): %v", err)
	}
	if !bytes.HasPrefix(b, []byte("%PDF")) {
		t.Fatalf("ожидался %%PDF-заголовок, получено %q", head(b))
	}
	if len(b) < 2000 {
		t.Fatalf("PDF подозрительно мал (%d байт) — вероятно, содержимое не отрисовалось", len(b))
	}
}

func head(b []byte) []byte {
	if len(b) > 8 {
		return b[:8]
	}
	return b
}
