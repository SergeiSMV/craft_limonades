package demo

import (
	"bytes"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/shopspring/decimal"
	"github.com/xuri/excelize/v2"

	"craftwms/internal/model"
	"craftwms/internal/repository"
	"craftwms/internal/service"
)

// demoOrderLine — строка «Реестра» 1С: накладная, заказ, клиент, адрес, код товара, количество.
type demoOrderLine struct {
	invoice, order, client, address, code string
	qty                                   int
}

// Выдуманные клиенты реестра: адреса городов без улиц.
var (
	// demoShipped — реестр на вчера: первый заказ собран и отгружен (раздел «Собраны» и
	// «Завершённые», журнал в портале), второй остался новым.
	demoShipped = []demoOrderLine{
		{"Д-0101", "З-5501", "ООО «Ромашка»", "Тула", "90101", 12},
		{"Д-0101", "З-5501", "ООО «Ромашка»", "Тула", "90103", 6},
		{"Д-0102", "З-5502", "ИП Васильков", "Рязань", "90201", 2},
	}
	// demoTomorrow — реестр на завтра: новые заказы для сборки на ТСД.
	demoTomorrow = []demoOrderLine{
		{"Д-0201", "З-5601", "ООО «Ромашка»", "Тула", "90101", 24},
		{"Д-0201", "З-5601", "ООО «Ромашка»", "Тула", "90102", 12},
		{"Д-0201", "З-5601", "ООО «Ромашка»", "Тула", "90301", 3},
		{"Д-0202", "З-5602", "ООО «Лето»", "Калуга", "90104", 10},
		{"Д-0202", "З-5602", "ООО «Лето»", "Калуга", "90109", 24},
		{"Д-0203", "З-5603", "ИП Васильков", "Рязань", "90105", 6},
		{"Д-0203", "З-5603", "ИП Васильков", "Рязань", "90202", 2},
		{"Д-0204", "З-5604", "ООО «Бриз»", "Коломна", "90107", 8},
		{"Д-0204", "З-5604", "ООО «Бриз»", "Коломна", "90108", 4},
	}
)

// picking — реестры на сборку загружаются так же, как оператор загружает файл 1С в портале;
// вчерашний заказ собирается по подбору, завершается и отгружается операциями ТСД.
func (s *seeder) picking() error {
	pk := repository.NewPickingRepository(s.pool)
	load := service.NewPickingLoadService(
		service.NewPickingRegistryService(repository.NewGoodsRepository(s.pool)),
		pk, repository.NewWarehouseRepository(s.pool))
	for _, f := range []struct {
		lines []demoOrderLine
		day   time.Time
	}{
		{demoShipped, s.now.AddDate(0, 0, -1)},
		{demoTomorrow, s.now.AddDate(0, 0, 1)},
	} {
		file, err := registryFile(f.lines, f.day)
		if err != nil {
			return err
		}
		name := "Реестр_" + f.day.Format("02-01-2006") + ".xlsx"
		if _, err := load.Load(s.ctx, model.DefaultWarehouseCode, name, s.adminID, bytes.NewReader(file)); err != nil {
			return err
		}
	}
	orderID, err := s.scan(`SELECT id::text FROM picking_orders WHERE order_number = 'З-5501'`)
	if err != nil {
		return err
	}
	return s.shipOrder(service.NewPickingTaskService(pk), orderID, s.borisID)
}

// shipOrder — сборка заказа кладовщиком: взять, короб отгрузки, пик по подбору операцией
// очереди, «Завершить сборку», ярлыки, отгрузка сканом всех коробов.
func (s *seeder) shipOrder(task *service.PickingTaskService, orderID, userID string) error {
	if err := task.Take(s.ctx, orderID, userID); err != nil {
		return err
	}
	box := uuid.NewString()
	if _, err := task.AddBox(s.ctx, orderID, userID, box); err != nil {
		return err
	}
	plan, err := task.Task(s.ctx, orderID)
	if err != nil {
		return err
	}
	for _, l := range plan.Lines {
		if l.Suggestion == nil {
			continue
		}
		for _, take := range l.Suggestion.Takes {
			_, err := s.ops.PickingPick(s.ctx, uuid.NewString(), repository.PickingPickInput{
				PickID: uuid.NewString(), OrderID: orderID, LineID: l.Line.ID, BoxID: box,
				SourceCellID: take.Source.CellID, SourceLoadUnitID: take.Source.LoadUnitID,
				InternalWarehouseID: take.Source.InternalWarehouseID,
				ProductionDate:      take.Source.BatchDate.Format(time.DateOnly),
				Qty:                 take.Qty, PickedBy: userID,
			})
			if err != nil {
				return fmt.Errorf("пик из %s: %w", take.Source.CellAddress, err)
			}
		}
	}
	shipment, err := task.Complete(s.ctx, orderID, userID)
	if err != nil {
		return err
	}
	ids := make([]string, 0, len(shipment.Boxes))
	for _, b := range shipment.Boxes {
		ids = append(ids, b.LoadUnitID)
	}
	if _, err := task.PrintLabels(s.ctx, orderID, ids, false); err != nil {
		return err
	}
	_, err = task.Ship(s.ctx, orderID, userID, ids)
	return err
}

// registryFile — «Реестр» в формате выгрузки 1С: лист «Реестр», 14 столбцов, даты числом Excel.
func registryFile(lines []demoOrderLine, day time.Time) ([]byte, error) {
	f := excelize.NewFile()
	defer func() { _ = f.Close() }()
	if err := f.SetSheetName("Sheet1", "Реестр"); err != nil {
		return nil, err
	}
	serial := excelDate(day)
	rows := [][]any{{"Номер накладной", "Дата накладной", "Номер заказа", "Дата заказа", "Статус", "Направление",
		"Клиент", "Адрес", "Код товара", "Товар", "Партия", "Количество", "Ячейка", "Вес, кг"}}
	for _, l := range lines {
		rows = append(rows, []any{l.invoice, serial, l.order, serial - 1, "К отгрузке", l.address,
			l.client, l.address, strings.Repeat("0", 11-len(l.code)) + l.code, goodName(l.code), "", l.qty, "",
			decimal.NewFromFloat(0.5 * float64(l.qty)).Round(1).InexactFloat64()})
	}
	for i, row := range rows {
		cell, err := excelize.CoordinatesToCellName(1, i+1)
		if err != nil {
			return nil, err
		}
		if err := f.SetSheetRow("Реестр", cell, &row); err != nil {
			return nil, err
		}
	}
	var buf bytes.Buffer
	if err := f.Write(&buf); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

// excelDate — дата числом Excel (дней от 30.12.1899): так 1С пишет даты в реестр.
func excelDate(day time.Time) int {
	base := time.Date(1899, 12, 30, 0, 0, 0, 0, time.UTC)
	d := time.Date(day.Year(), day.Month(), day.Day(), 0, 0, 0, 0, time.UTC)
	return int(d.Sub(base).Hours() / 24)
}

// goodName — наименование товара демо-справочника по коду (для столбца «Товар» реестра).
func goodName(code string) string {
	for _, g := range demoGoods {
		if g.code == code {
			return g.name
		}
	}
	return ""
}
