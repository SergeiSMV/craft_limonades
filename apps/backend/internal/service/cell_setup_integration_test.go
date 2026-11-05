package service_test

import (
	"bytes"
	"context"
	"errors"
	"os"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"

	"craftwms/internal/importer"
	"craftwms/internal/model"
	"craftwms/internal/repository"
	"craftwms/internal/service"
	"craftwms/internal/testutil"
)

const rackLabelsSamplePath = "../importer/testdata/rack_labels_sample.xlsx"

func newCellSetupSvc(pool *pgxpool.Pool) *service.CellSetupService {
	return service.NewCellSetupService(pool, repository.NewWarehouseRepository(pool), repository.NewCellRepository(pool))
}

// importFile загружает файл ячеек в склад SHB.
func importFile(t *testing.T, pool *pgxpool.Pool, path string) *service.CellsImportReport {
	t.Helper()
	f, err := os.Open(path)
	if err != nil {
		t.Fatalf("открыть %s: %v", path, err)
	}
	defer func() { _ = f.Close() }()
	rep, err := newImportSvc(pool).ImportCells(context.Background(), f, "SHB", "Шабулина")
	if err != nil {
		t.Fatalf("ImportCells(%s): %v", path, err)
	}
	return rep
}

// TestCellSetup_rackLabelsRoundTrip — настоящий файл rack_labels: загрузка, страница «Ячейки»
// с теми же итогами, что у скрипта; выгрузка и обратная загрузка выгрузки ничего не меняют.
func TestCellSetup_rackLabelsRoundTrip(t *testing.T) {
	pool := testutil.StartPostgres(t)
	ctx := context.Background()
	rep := importFile(t, pool, rackLabelsSamplePath)
	if rep.CellsCreated != 522 || rep.RacksCreated != 66 || len(rep.Skipped) != 0 {
		t.Fatalf("загрузка: ячеек %d/522, стеллажей %d/66, пропущено %+v", rep.CellsCreated, rep.RacksCreated, rep.Skipped)
	}

	svc := newCellSetupSvc(pool)
	setup, err := svc.Setup(ctx, "SHB")
	if err != nil {
		t.Fatalf("Setup: %v", err)
	}
	// Ячейка приёмки на страницу не попадает.
	if len(setup.Cells) != 522 || len(setup.Racks) != 66 {
		t.Fatalf("страница: ячеек %d/522, стеллажей %d/66", len(setup.Cells), len(setup.Racks))
	}
	var small, floors, barcode, cards int
	for _, c := range setup.Cells {
		if c.LabelSmall {
			small++
		}
		if c.IsFloor {
			floors++
		}
		if c.LabelBarcode {
			barcode++
		}
		if c.RackCode == nil {
			t.Errorf("у ячейки %s нет стеллажа", c.Address)
		}
	}
	for _, r := range setup.Racks {
		if r.SideCard {
			cards++
		}
	}
	if small != 30 || floors != 177 || barcode != 129 || cards != 45 {
		t.Errorf("итоги: малых %d/30, нижних %d/177, со штрих-кодом %d/129, с карточкой %d/45", small, floors, barcode, cards)
	}
	// Натуральный порядок: B-1-2-9 раньше B-1-2-10, стеллаж B-02 раньше B-10.
	if idx(setup.Cells, "B-1-2-9") > idx(setup.Cells, "B-1-2-10") {
		t.Error("ячейки не в натуральном порядке адреса")
	}

	// Выгрузка → разбор выгрузки: то же содержимое, что в базе.
	data, name, err := svc.ExportXLSX(ctx, "SHB")
	if err != nil || name != "cells-SHB.xlsx" {
		t.Fatalf("ExportXLSX: %q %v", name, err)
	}
	parsed, err := importer.ParseCells(bytes.NewReader(data))
	if err != nil || len(parsed.Errors) != 0 || len(parsed.Cells) != 522 || len(parsed.Racks) != 66 {
		t.Fatalf("разбор выгрузки: %v, ячеек %d, стеллажей %d, ошибок %+v", err, len(parsed.Cells), len(parsed.Racks), parsed.Errors)
	}
	for i, c := range parsed.Cells {
		s := setup.Cells[i]
		if c.Address != s.Address || c.RackCode != *s.RackCode || c.LabelSmall != s.LabelSmall ||
			c.IsFloor != s.IsFloor || c.LabelBarcode != s.LabelBarcode {
			t.Fatalf("строка %d выгрузки %+v не совпадает с базой %+v", i+2, c, s)
		}
	}

	// Обратная загрузка выгрузки: всё обновлено, ничего не создано и не изменилось.
	f, err := newImportSvc(pool).ImportCells(ctx, bytes.NewReader(data), "SHB", "Шабулина")
	if err != nil || f.CellsCreated != 0 || f.CellsUpdated != 522 || f.RacksCreated != 0 {
		t.Fatalf("обратная загрузка: %+v %v", f, err)
	}
	again, err := svc.Setup(ctx, "SHB")
	if err != nil {
		t.Fatal(err)
	}
	for i := range again.Cells {
		if !sameCell(again.Cells[i], setup.Cells[i]) {
			t.Fatalf("после обратной загрузки ячейка изменилась: %+v → %+v", setup.Cells[i], again.Cells[i])
		}
	}
}

// TestCellSetup_updateSettings — массовая правка галочек: меняются только заданные поля и только
// у выбранных ячеек; карточка — у их стеллажей; чужие ячейки и пустой патч отклоняются.
func TestCellSetup_updateSettings(t *testing.T) {
	pool := testutil.StartPostgres(t)
	ctx := context.Background()
	importFile(t, pool, cellsSamplePath)
	svc := newCellSetupSvc(pool)

	setup, err := svc.Setup(ctx, "SHB")
	if err != nil {
		t.Fatal(err)
	}
	// Две ячейки стеллажа M1-7 (без карточки, со штрих-кодом, большая балка).
	a, b := byAddr(t, setup, "M1-7-1-2"), byAddr(t, setup, "M1-7-1-3")
	if a.LabelSmall || !a.LabelBarcode || a.IsFloor {
		t.Fatalf("исходное состояние M1-7-1-2: %+v", a)
	}
	yes, no := true, false
	res, err := svc.UpdateSettings(ctx, "SHB", model.CellSettingsPatch{
		CellIDs: []string{a.ID, b.ID, a.ID}, LabelSmall: &yes, LabelBarcode: &no, SideCard: &yes,
	})
	if err != nil {
		t.Fatalf("UpdateSettings: %v", err)
	}
	if res.CellsUpdated != 2 || res.RacksUpdated != 1 {
		t.Errorf("изменено ячеек %d (ждали 2), стеллажей %d (ждали 1)", res.CellsUpdated, res.RacksUpdated)
	}
	after, err := svc.Setup(ctx, "SHB")
	if err != nil {
		t.Fatal(err)
	}
	a2, other := byAddr(t, after, "M1-7-1-2"), byAddr(t, after, "M1-7-1-4")
	if !a2.LabelSmall || a2.LabelBarcode || a2.IsFloor != a.IsFloor {
		t.Errorf("M1-7-1-2 после правки: %+v", a2)
	}
	if other.LabelSmall || !other.LabelBarcode {
		t.Errorf("невыбранная ячейка изменилась: %+v", other)
	}
	if !rackCard(t, after, "M1-7") {
		t.Error("стеллаж M1-7: карточка не включилась")
	}

	// Повтор того же — ничего не меняется, счётчики нулевые.
	res, err = svc.UpdateSettings(ctx, "SHB", model.CellSettingsPatch{CellIDs: []string{a.ID, b.ID}, LabelSmall: &yes, SideCard: &yes})
	if err != nil || res.CellsUpdated != 0 || res.RacksUpdated != 0 {
		t.Errorf("повтор: %+v %v", res, err)
	}

	// Ошибки до записи.
	cases := map[string]struct {
		p    model.CellSettingsPatch
		want error
	}{
		"нет ячеек":    {model.CellSettingsPatch{LabelSmall: &yes}, service.ErrNoCellsSelected},
		"нет галочек":  {model.CellSettingsPatch{CellIDs: []string{a.ID}}, service.ErrEmptyCellsPatch},
		"не UUID":      {model.CellSettingsPatch{CellIDs: []string{"M1-7-1-2"}, LabelSmall: &yes}, service.ErrInvalidCellIDs},
		"чужая ячейка": {model.CellSettingsPatch{CellIDs: []string{a.ID, "00000000-0000-0000-0000-000000000001"}, LabelSmall: &no}, repository.ErrForeignCells},
	}
	for name, c := range cases {
		if _, err := svc.UpdateSettings(ctx, "SHB", c.p); !errors.Is(err, c.want) {
			t.Errorf("%s: ошибка %v, ждали %v", name, err, c.want)
		}
	}
	// «Чужая ячейка» не применила и свою часть: транзакция целиком.
	if got := byAddr(t, mustSetup(t, svc), "M1-7-1-2"); !got.LabelSmall {
		t.Error("отклонённый патч частично применился")
	}
	// Ячейка приёмки не правится: её нет на странице, и по id она тоже отклоняется.
	var dflt string
	if err := pool.QueryRow(ctx, `SELECT id::text FROM cells WHERE is_default`).Scan(&dflt); err != nil {
		t.Fatal(err)
	}
	if _, err := svc.UpdateSettings(ctx, "SHB", model.CellSettingsPatch{CellIDs: []string{dflt}, IsFloor: &yes}); !errors.Is(err, repository.ErrForeignCells) {
		t.Errorf("ячейка приёмки: %v, ждали ErrForeignCells", err)
	}
	if _, err := svc.Setup(ctx, "NOPE"); !errors.Is(err, repository.ErrNotFound) {
		t.Errorf("неизвестный склад: %v", err)
	}
}

func mustSetup(t *testing.T, svc *service.CellSetupService) *model.CellsSetup {
	t.Helper()
	s, err := svc.Setup(context.Background(), "SHB")
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func byAddr(t *testing.T, s *model.CellsSetup, address string) model.CellSetup {
	t.Helper()
	for _, c := range s.Cells {
		if c.Address == address {
			return c
		}
	}
	t.Fatalf("нет ячейки %s", address)
	return model.CellSetup{}
}

func rackCard(t *testing.T, s *model.CellsSetup, code string) bool {
	t.Helper()
	for _, r := range s.Racks {
		if r.Code == code {
			return r.SideCard
		}
	}
	t.Fatalf("нет стеллажа %s", code)
	return false
}

func idx(cells []model.CellSetup, address string) int {
	for i, c := range cells {
		if c.Address == address {
			return i
		}
	}
	return -1
}

// sameCell сравнивает ячейки по значениям (указатели на стеллаж — разные адреса памяти).
func sameCell(a, b model.CellSetup) bool {
	return a.ID == b.ID && a.Address == b.Address && *a.RackID == *b.RackID && *a.RackCode == *b.RackCode &&
		a.IsFloor == b.IsFloor && a.LabelSmall == b.LabelSmall && a.LabelBarcode == b.LabelBarcode
}
