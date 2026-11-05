package service_test

import (
	"bytes"
	"context"
	"errors"
	"testing"

	"github.com/google/uuid"

	"craftwms/internal/labels"
	"craftwms/internal/model"
	"craftwms/internal/repository"
	"craftwms/internal/service"
	"craftwms/internal/testutil"
)

func pdfPages(pdf []byte) int { return bytes.Count(pdf, []byte("/Type /Page\n")) }

// TestCellLabelsPDF — настоящий файл rack_labels: весь склад печатается теми же листами, что
// у скрипта (большая балка 492 этикетки — 123 листа, малая 30 — 5, карточек 45 — 23), выборка
// печатает только своё, ошибки выборки различимы.
func TestCellLabelsPDF(t *testing.T) {
	pool := testutil.StartPostgres(t)
	ctx := context.Background()
	importFile(t, pool, rackLabelsSamplePath)
	svc := service.NewLabelService(repository.NewWarehouseRepository(pool), repository.NewCellRepository(pool))

	for kind, want := range map[string]struct {
		pages int
		name  string
	}{
		service.LabelKindLarge: {123, "labels_large.pdf"},
		service.LabelKindSmall: {5, "labels_small.pdf"},
		service.LabelKindCards: {23, "side_cards.pdf"},
	} {
		pdf, name, err := svc.CellLabelsPDF(ctx, "SHB", kind, nil)
		if err != nil || name != want.name || pdfPages(pdf) != want.pages {
			t.Errorf("%s: %v %s, листов %d, ждали %d", kind, err, name, pdfPages(pdf), want.pages)
		}
	}

	// Ячейки выборки: большая балка, малая балка — по адресу из файла.
	setup, err := newCellSetupSvc(pool).Setup(ctx, "SHB")
	if err != nil {
		t.Fatal(err)
	}
	var large, small model.CellSetup
	for _, c := range setup.Cells {
		if c.LabelSmall && small.ID == "" {
			small = c
		}
		if !c.LabelSmall && large.ID == "" && c.RackCode != nil && hasCard(setup.Racks, *c.RackCode) {
			large = c
		}
	}
	if large.ID == "" || small.ID == "" {
		t.Fatal("в образце нет нужных ячеек")
	}
	if pdf, _, err := svc.CellLabelsPDF(ctx, "SHB", service.LabelKindLarge, []string{large.ID, small.ID, large.ID}); err != nil || pdfPages(pdf) != 1 {
		t.Errorf("выборка на большую балку: %v, листов %d", err, pdfPages(pdf))
	}
	// Карточка стеллажа выбранной ячейки печатается целиком — одна карточка, один лист.
	if pdf, _, err := svc.CellLabelsPDF(ctx, "SHB", service.LabelKindCards, []string{large.ID}); err != nil || pdfPages(pdf) != 1 {
		t.Errorf("карточка выборки: %v, листов %d", err, pdfPages(pdf))
	}
	if _, _, err := svc.CellLabelsPDF(ctx, "SHB", service.LabelKindSmall, []string{large.ID}); !errors.Is(err, labels.ErrNothingToPrint) {
		t.Errorf("малых в выборке нет: %v", err)
	}

	// Ячейка приёмки этикетки не имеет: её адрес кириллицей Code128 не кодирует (P4-03).
	var defID string
	if err := pool.QueryRow(ctx, `SELECT id::text FROM cells WHERE is_default`).Scan(&defID); err != nil {
		t.Fatal(err)
	}
	for name, c := range map[string]struct {
		kind string
		ids  []string
		want error
	}{
		"чужая ячейка":    {service.LabelKindLarge, []string{uuid.NewString()}, repository.ErrForeignCells},
		"ячейка приёмки":  {service.LabelKindLarge, []string{defID}, repository.ErrForeignCells},
		"не UUID":         {service.LabelKindLarge, []string{"x"}, service.ErrInvalidCellIDs},
		"неизвестный вид": {"huge", nil, service.ErrUnknownLabelKind},
	} {
		if _, _, err := svc.CellLabelsPDF(ctx, "SHB", c.kind, c.ids); !errors.Is(err, c.want) {
			t.Errorf("%s: %v, ждали %v", name, err, c.want)
		}
	}
	if _, _, err := svc.CellLabelsPDF(ctx, "NOPE", service.LabelKindLarge, nil); !errors.Is(err, repository.ErrNotFound) {
		t.Errorf("неизвестный склад: %v", err)
	}
}

func hasCard(racks []model.Rack, code string) bool {
	for _, r := range racks {
		if r.Code == code {
			return r.SideCard
		}
	}
	return false
}
