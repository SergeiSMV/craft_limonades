package service

import (
	"context"
	"sort"

	"craftwms/internal/labels"
	"craftwms/internal/model"
)

// warehouseCodeRepo — резолв склада по коду (для ?warehouse=SHB).
type warehouseCodeRepo interface {
	IDByCode(ctx context.Context, code string) (string, error)
}

// cellLabelRepo — чтение ячеек склада для этикеток.
type cellLabelRepo interface {
	LabelsByWarehouse(ctx context.Context, warehouseID string) ([]model.CellLabel, error)
}

// LabelService — генерация PDF-этикеток ячеек склада (P-FS-05).
type LabelService struct {
	warehouses warehouseCodeRepo
	cells      cellLabelRepo
}

// NewLabelService собирает сервис этикеток.
func NewLabelService(warehouses warehouseCodeRepo, cells cellLabelRepo) *LabelService {
	return &LabelService{warehouses: warehouses, cells: cells}
}

// CellLabelsPDF отдаёт PDF-этикеток всех активных ячеек склада (по коду). Неизвестный склад →
// repository.ErrNotFound (хендлер → 404). Ячейки сортируются натурально по адресу.
func (s *LabelService) CellLabelsPDF(ctx context.Context, warehouseCode string) ([]byte, error) {
	whID, err := s.warehouses.IDByCode(ctx, warehouseCode)
	if err != nil {
		return nil, err
	}
	cells, err := s.cells.LabelsByWarehouse(ctx, whID)
	if err != nil {
		return nil, err
	}
	sort.Slice(cells, func(i, j int) bool {
		return naturalLess(cells[i].Address, cells[j].Address)
	})
	return labels.Render(cells)
}

// naturalLess сравнивает адреса «натурально»: числовые сегменты — по значению, а не лексикографически
// (чтобы M1-1-2-1 шёл раньше M1-1-10-1). Побайтово, разбивая на цифровые и нецифровые пробеги.
func naturalLess(a, b string) bool {
	ai, bi := 0, 0
	for ai < len(a) && bi < len(b) {
		ad, bd := isDigit(a[ai]), isDigit(b[bi])
		if ad && bd {
			an, aj := digitRun(a, ai)
			bn, bj := digitRun(b, bi)
			if an != bn {
				return an < bn
			}
			ai, bi = aj, bj
			continue
		}
		if a[ai] != b[bi] {
			return a[ai] < b[bi]
		}
		ai++
		bi++
	}
	// Более короткая строка — раньше (все общие сегменты равны).
	return len(a)-ai < len(b)-bi
}

func isDigit(c byte) bool { return c >= '0' && c <= '9' }

// digitRun читает цифровой пробег с позиции i, возвращает его число и позицию после него.
func digitRun(s string, i int) (val int, next int) {
	for i < len(s) && isDigit(s[i]) {
		val = val*10 + int(s[i]-'0')
		i++
	}
	return val, i
}
