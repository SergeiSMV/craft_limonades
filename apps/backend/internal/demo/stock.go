package demo

import (
	"github.com/google/uuid"
	"github.com/shopspring/decimal"

	"craftwms/internal/model"
	"craftwms/internal/repository"
)

// demoPlace — что лежит в ячейке после ввода остатков: товар, партия (дней назад), количество;
// box — в коробе (ГЕ), а не россыпью.
type demoPlace struct {
	cell, code string
	daysAgo    int
	qty        int64
	box        bool
}

// demoStock — стартовые остатки. У части лимонадов две партии в разных ячейках — чтобы подбор
// сборки показал FEFO; часть товара в коробах — чтобы были видны ГЕ и их содержимое.
var demoStock = []demoPlace{
	{"A-01-1", "90101", 40, 60, false},
	{"A-01-2", "90101", 10, 48, false},
	{"A-01-3", "90102", 25, 36, false},
	{"A-02-1", "90103", 30, 42, false},
	{"A-02-2", "90104", 20, 30, false},
	{"A-02-3", "90105", 15, 24, false},
	{"A-03-1", "90106", 35, 18, false},
	{"A-03-2", "90107", 12, 20, false},
	{"A-03-3", "90108", 8, 16, false},
	{"A-04-1", "90109", 45, 72, false},
	{"A-04-2", "90110", 5, 48, false},
	{"B-01-1", "90201", 60, 12, false},
	{"B-01-2", "90202", 50, 12, false},
	{"B-02-1", "90203", 40, 9, false},
	{"B-02-2", "90204", 30, 6, false},
	{"C-01-1", "90102", 6, 24, true},
	{"C-01-2", "90105", 4, 24, true},
	{"C-02-1", "90107", 3, 20, true},
	{"C-02-2", "90109", 2, 24, true},
	{"A" + model.FloorStorageSuffix, "90301", 90, 200, false},
	{"A" + model.FloorStorageSuffix, "90302", 90, 150, false},
	{"A" + model.FloorStorageSuffix, "90303", 120, 10, false},
}

// stockEntry — стартовые остатки «Вводом остатков», как их заводят перед пилотом: сессия,
// ячейка за ячейкой checkpoint'ом, финал переносит в остатки и даёт документ «ДО».
func (s *seeder) stockEntry() error {
	session := uuid.NewString()
	if _, err := s.ops.StockEntryStart(s.ctx, uuid.NewString(), session, s.warehouseID, s.annaID); err != nil {
		return err
	}
	byCell := map[string]*repository.StockEntryCellInput{}
	var order []string
	for _, p := range demoStock {
		in, ok := byCell[p.cell]
		if !ok {
			in = &repository.StockEntryCellInput{CellID: s.cells[p.cell]}
			byCell[p.cell] = in
			order = append(order, p.cell)
		}
		line := repository.StockEntryLineInput{
			GoodID: s.goods[p.code], ProductionDate: s.date(p.daysAgo), Qty: decimal.NewFromInt(p.qty),
		}
		if p.box {
			box := uuid.NewString()
			in.LoadUnits = append(in.LoadUnits, repository.LoadUnitInput{ID: box, Kind: model.LoadUnitBox})
			line.LoadUnitID = box
		}
		in.Lines = append(in.Lines, line)
	}
	for _, cell := range order {
		if _, err := s.ops.StockEntryCheckpoint(s.ctx, uuid.NewString(), session, *byCell[cell]); err != nil {
			return err
		}
	}
	_, err := s.ops.StockEntryFinalize(s.ctx, uuid.NewString(), session)
	return err
}

// receipt — вчерашняя приёмка в ячейку приёмки: россыпь и короб. Оприходование заводит задание
// на размещение — в «Заданиях» ТСД есть что взять.
func (s *seeder) receipt() error {
	box := uuid.NewString()
	yesterday := s.now.AddDate(0, 0, -1)
	_, err := s.ops.ReceiptSubmit(s.ctx, uuid.NewString(), repository.ReceiptSubmitInput{
		ReceiptID: uuid.NewString(), WarehouseID: s.warehouseID, SupplierID: s.suppliers[0],
		CreatedBy: s.annaID,
		Doc:       model.SupplierDoc{Number: "СК-1045", Date: yesterday},
		LoadUnits: []repository.LoadUnitInput{{ID: box, Kind: model.LoadUnitBox}},
		Lines: []model.ReceiptLineInput{
			{GoodID: s.goods["90101"], ProductionDate: s.date(2), Qty: decimal.NewFromInt(24)},
			{GoodID: s.goods["90104"], ProductionDate: s.date(3), Qty: decimal.NewFromInt(12)},
			{GoodID: s.goods["90106"], ProductionDate: s.date(2), Qty: decimal.NewFromInt(12), LoadUnitID: box},
		},
	})
	return err
}

// problems — две открытые проблемы склада: бой (решение офиса - списать) и «прочее» с
// комментарием. Товар уходит на внутренний склад «Брак» в той же ячейке.
func (s *seeder) problems() error {
	for _, p := range []struct {
		cell, code, reason, comment string
		daysAgo                     int
		qty                         int64
	}{
		{"A-02-1", "90103", model.ProblemReasonBreakage, "", 30, 2},
		{"A-03-2", "90107", model.ProblemReasonOther, "Помята этикетка", 12, 1},
	} {
		_, err := s.ops.ProblemSubmit(s.ctx, uuid.NewString(), repository.ProblemSubmitInput{
			ProblemID: uuid.NewString(), WarehouseID: s.warehouseID, CreatedBy: s.annaID,
			GoodID: s.goods[p.code], ProductionDate: s.date(p.daysAgo), Qty: decimal.NewFromInt(p.qty),
			CellID: s.cells[p.cell], FromInternalWarehouseID: s.mainIWH, ToInternalWarehouseID: s.defectIWH,
			Reason: p.reason, Comment: p.comment,
		})
		if err != nil {
			return err
		}
	}
	return nil
}
