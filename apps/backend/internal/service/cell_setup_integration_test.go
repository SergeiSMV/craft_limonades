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

// TestCellSetup_rackLabelsRoundTrip - настоящий файл rack_labels: загрузка, страница «Ячейки»
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
	// Карточка по умолчанию (лист racks, решение 2026-11-05): ячейки стеллажей с карточкой без
	// штрих-кода на балке - как печатал rack_labels.
	parsedFile := parseSample(t, rackLabelsSamplePath)
	rackCard := map[string]bool{}
	for _, r := range parsedFile.Racks {
		rackCard[r.Code] = r.SideCard
	}
	cardRacks := map[string]bool{}
	var small, floors, barcode int
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
			t.Fatalf("у ячейки %s нет стеллажа", c.Address)
		}
		if want := rackCard[*c.RackCode] && !c.LabelBarcode; c.SideCard != want {
			t.Errorf("ячейка %s: side_card %v, ждали %v", c.Address, c.SideCard, want)
		}
		if c.SideCard {
			cardRacks[*c.RackCode] = true
		}
	}
	if small != 30 || floors != 177 || barcode != 129 || len(cardRacks) != 45 {
		t.Errorf("итоги: малых %d/30, нижних %d/177, со штрих-кодом %d/129, стеллажей с карточкой %d/45",
			small, floors, barcode, len(cardRacks))
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
			c.IsFloor != s.IsFloor || c.LabelBarcode != s.LabelBarcode || c.SideCard == nil || *c.SideCard != s.SideCard {
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

	// Галочка, не совпадающая с правилом по умолчанию (ячейка со штрих-кодом на карточке и ячейка
	// стеллажа с карточкой без неё), переживает круг «выгрузка → загрузка»: колонка ячейки главнее.
	var withCode, withoutCode model.CellSetup
	for _, c := range again.Cells {
		if c.LabelBarcode && !c.SideCard && withCode.ID == "" {
			withCode = c
		}
		if !c.LabelBarcode && c.SideCard && withoutCode.ID == "" {
			withoutCode = c
		}
	}
	yes, no := true, false
	if _, err := svc.UpdateSettings(ctx, "SHB", model.CellSettingsPatch{CellIDs: []string{withCode.ID}, SideCard: &yes}); err != nil {
		t.Fatal(err)
	}
	if _, err := svc.UpdateSettings(ctx, "SHB", model.CellSettingsPatch{CellIDs: []string{withoutCode.ID}, SideCard: &no}); err != nil {
		t.Fatal(err)
	}
	edited := mustSetup(t, svc)
	data, _, err = svc.ExportXLSX(ctx, "SHB")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := newImportSvc(pool).ImportCells(ctx, bytes.NewReader(data), "SHB", "Шабулина"); err != nil {
		t.Fatal(err)
	}
	final := mustSetup(t, svc)
	for i := range final.Cells {
		if !sameCell(final.Cells[i], edited.Cells[i]) {
			t.Fatalf("круг после правки галочек: %+v → %+v", edited.Cells[i], final.Cells[i])
		}
	}
	if !byAddr(t, final, withCode.Address).SideCard || byAddr(t, final, withoutCode.Address).SideCard {
		t.Error("галочки карточки не пережили выгрузку и загрузку")
	}
}

func parseSample(t *testing.T, path string) *importer.CellsParseResult {
	t.Helper()
	f, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = f.Close() }()
	res, err := importer.ParseCells(f)
	if err != nil {
		t.Fatal(err)
	}
	return res
}

// TestCellSetup_updateSettings - массовая правка галочек: меняются только заданные поля и только
// у выбранных ячеек, галочка карточки - тоже у ячеек и только со стеллажом; чужие ячейки и пустой
// патч отклоняются.
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
	if res.CellsUpdated != 2 {
		t.Errorf("изменено ячеек %d (ждали 2)", res.CellsUpdated)
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
	if !a2.SideCard || !byAddr(t, after, "M1-7-1-3").SideCard || byAddr(t, after, "M1-7-1-4").SideCard {
		t.Error("галочка карточки: включиться должна только у выбранных ячеек")
	}

	// Повтор того же - ничего не меняется, счётчики нулевые.
	res, err = svc.UpdateSettings(ctx, "SHB", model.CellSettingsPatch{CellIDs: []string{a.ID, b.ID}, LabelSmall: &yes, SideCard: &yes})
	if err != nil || res.CellsUpdated != 0 {
		t.Errorf("повтор: %+v %v", res, err)
	}

	// Ячейке без стеллажа галочка карточки не ставится: строки некуда поставить.
	if _, err := pool.Exec(ctx, `UPDATE cells SET rack_id = NULL WHERE id = $1`, b.ID); err != nil {
		t.Fatal(err)
	}
	res, err = svc.UpdateSettings(ctx, "SHB", model.CellSettingsPatch{CellIDs: []string{b.ID}, SideCard: &no})
	if err != nil || res.CellsUpdated != 1 {
		t.Fatalf("снять галочку у ячейки без стеллажа: %+v %v", res, err)
	}
	res, err = svc.UpdateSettings(ctx, "SHB", model.CellSettingsPatch{CellIDs: []string{b.ID}, SideCard: &yes})
	if err != nil || res.CellsUpdated != 0 || byAddr(t, mustSetup(t, svc), "M1-7-1-3").SideCard {
		t.Errorf("галочка ячейке без стеллажа: %+v %v", res, err)
	}

	// Ошибки до записи.
	cases := map[string]struct {
		p    model.CellSettingsPatch
		want error
	}{
		"нет ячеек":    {model.CellSettingsPatch{LabelSmall: &yes}, model.ErrNoCellsSelected},
		"нет галочек":  {model.CellSettingsPatch{CellIDs: []string{a.ID}}, model.ErrEmptyCellsPatch},
		"не UUID":      {model.CellSettingsPatch{CellIDs: []string{"M1-7-1-2"}, LabelSmall: &yes}, model.ErrInvalidCellIDs},
		"чужая ячейка": {model.CellSettingsPatch{CellIDs: []string{a.ID, "00000000-0000-0000-0000-000000000001"}, LabelSmall: &no}, model.ErrForeignCells},
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
	if _, err := svc.UpdateSettings(ctx, "SHB", model.CellSettingsPatch{CellIDs: []string{dflt}, IsFloor: &yes}); !errors.Is(err, model.ErrForeignCells) {
		t.Errorf("ячейка приёмки: %v, ждали ErrForeignCells", err)
	}
	if _, err := svc.Setup(ctx, "NOPE"); !errors.Is(err, model.ErrNotFound) {
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

func idx(cells []model.CellSetup, address string) int {
	for i, c := range cells {
		if c.Address == address {
			return i
		}
	}
	return -1
}

// sameCell сравнивает ячейки по значениям (указатели на стеллаж - разные адреса памяти).
func sameCell(a, b model.CellSetup) bool {
	return a.ID == b.ID && a.Address == b.Address && *a.RackID == *b.RackID && *a.RackCode == *b.RackCode &&
		a.IsFloor == b.IsFloor && a.LabelSmall == b.LabelSmall && a.LabelBarcode == b.LabelBarcode &&
		a.SideCard == b.SideCard
}
