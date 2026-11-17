package repository

import (
	"context"
	"errors"
	"fmt"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/shopspring/decimal"

	"craftwms/internal/model"
)

// isolatorCode - код внутреннего склада «Изолятор» (миграция 23): туда приход переводит товар
// с расхождением ЧЗ (CZ-05, ADHOC-46). Флага у склада нет, поэтому - по коду, как его и завела миграция.
const isolatorCode = "ISOLATOR"

// CZIntakeInput - приход ЧЗ: что приёмка (CZ-05) или финал ввода остатков (ADHOC-46) отдают
// общей записи марок, упаковок и проблем с расхождением.
type CZIntakeInput struct {
	// ReceiptID - приёмка, задание на размещение которой правят проблемы россыпи; пусто -
	// ввод остатков: задания у него нет.
	ReceiptID   string
	WarehouseID string
	CreatedBy   string
	LoadUnits   []LoadUnitInput
	// Lines - строки прихода; ячейка у каждой уже подставлена.
	Lines    []model.ReceiptLineInput
	CZGroups []model.CZAggregate
}

// receiveCZ записывает марки и агрегаты ЧЗ проведённого прихода - в его транзакции.
//
// Что: короба ЧЗ (это ГЕ прихода) и групповые упаковки, марки с местом - в коробе или россыпью
// в ячейке строки на складе по умолчанию, признак «маркируемый» у их товаров; расхождения с ЧЗ -
// проблемы склада с переводом в «Изолятор».
// Зачем после проводки: место марки в коробе - размещённая ГЕ, а проблема переводит уже
// оприходованный остаток. Всё в одной транзакции: приход без своих марок означал бы, что
// «где лежит марка» отвечает неправду.
func receiveCZ(ctx context.Context, q Querier, in CZIntakeInput) error {
	if err := insertIntakeAggregates(ctx, q, in); err != nil {
		return err
	}
	hasMarks := false
	for _, ln := range in.Lines {
		hasMarks = hasMarks || len(ln.Marks) > 0
	}
	if !hasMarks {
		return nil
	}

	iwh, err := defaultInternalWarehouse(ctx, q)
	if err != nil {
		return err
	}
	boxes := map[string]string{} // ГЕ → код короба ЧЗ
	for _, lu := range in.LoadUnits {
		if lu.CZCode != "" {
			boxes[lu.ID] = lu.CZCode
		}
	}
	goodOfGTIN := map[string]string{}
	var marks []model.CZMark
	var goods []string
	for _, ln := range in.Lines {
		if len(ln.Marks) == 0 {
			continue
		}
		if err := guardMarksOfGood(ctx, q, ln, goodOfGTIN); err != nil {
			return err
		}
		batchID, err := existingBatch(ctx, q, ln.GoodID, ln.ProductionDate)
		if err != nil {
			return err
		}
		for _, m := range ln.Marks {
			mark := model.CZMark{
				CIS: m.CIS, GoodID: ln.GoodID, BatchID: batchID, AggregateCode: m.AggregateCode,
				LoadUnitID: ln.LoadUnitID,
			}
			if ln.LoadUnitID == "" {
				mark.CellID, mark.InternalWarehouseID = ln.CellID, iwh
			}
			marks = append(marks, mark)
		}
		goods = append(goods, ln.GoodID)
	}
	if err := insertCZMarks(ctx, q, marks); err != nil {
		return err
	}
	if err := markGoodsCZ(ctx, q, goods); err != nil {
		return err
	}
	return intakeCZProblems(ctx, q, in, boxes)
}

// insertIntakeAggregates заводит короба ЧЗ прихода и его групповые упаковки - родитель раньше
// вложенной: внешний ключ parent_code не примет упаковку раньше её короба.
func insertIntakeAggregates(ctx context.Context, q Querier, in CZIntakeInput) error {
	done := map[string]bool{"": true}
	for _, lu := range in.LoadUnits {
		if lu.CZCode == "" {
			continue
		}
		if err := insertCZAggregate(ctx, q, model.CZAggregate{
			Code: lu.CZCode, Kind: model.CZAggregateBox, LoadUnitID: lu.ID,
		}); err != nil {
			return err
		}
		done[lu.CZCode] = true
	}
	// Вложенность проверил сервис (родитель - упаковка того же прихода, без циклов), поэтому
	// каждый проход вставляет хотя бы одну упаковку; проход без вставок - защита от зацикливания.
	pending := in.CZGroups
	for len(pending) > 0 {
		var rest []model.CZAggregate
		for _, g := range pending {
			if !done[g.ParentCode] {
				rest = append(rest, g)
				continue
			}
			if err := insertCZAggregate(ctx, q, g); err != nil {
				return err
			}
			done[g.Code] = true
		}
		if len(rest) == len(pending) {
			return model.ErrUnknownReference
		}
		pending = rest
	}
	return nil
}

// guardMarksOfGood - GTIN каждой марки строки - ШК её товара. Скан привязал незнакомый GTIN
// к товару раньше (bind_barcode идёт в очереди первым), так что GTIN без товара или с другим
// товаром - расхождение тела с базой, а не рабочая ситуация.
// [cache] - GTIN → товар: в коробе десятки марок одного GTIN.
func guardMarksOfGood(ctx context.Context, q Querier, ln model.ReceiptLineInput, cache map[string]string) error {
	for _, m := range ln.Marks {
		gtin := m.CIS[2:16]
		good, ok := cache[gtin]
		if !ok {
			ref, err := goodByGTIN(ctx, q, gtin)
			if err != nil {
				return err
			}
			good, cache[gtin] = ref.ID, ref.ID
		}
		if good != ln.GoodID {
			return fmt.Errorf("%w: %s", model.ErrCZMarkGoodMismatch, m.CIS)
		}
	}
	return nil
}

// intakeCZProblems заводит проблемы склада по маркам с расхождением (CZ-05).
//
// Короб ЧЗ, в котором есть хоть одна такая марка, уходит в «Изолятор» целиком: короб - одна
// ГЕ с одной меткой склада, и все его марки - марки проблемы. Марки россыпью (и в своём коробе
// с QR) - проблемой на товар и партию строки с их числом, отдельной на каждую причину; из
// своего короба они вынимаются в россыпь «Изолятора» той же ячейки.
// Причина короба - «чужая марка», если такая в нём есть: решение по ней шире (можно разместить).
func intakeCZProblems(ctx context.Context, q Querier, in CZIntakeInput, boxes map[string]string) error {
	type boxIssue struct{ foreign, retired bool }
	boxIssues := map[string]*boxIssue{}
	var looseKeys []problemKey
	loose := map[problemKey][]string{}
	for i, ln := range in.Lines {
		for _, m := range ln.Marks {
			if m.Discrepancy == "" {
				continue
			}
			if _, isBox := boxes[ln.LoadUnitID]; isBox {
				bi := boxIssues[ln.LoadUnitID]
				if bi == nil {
					bi = &boxIssue{}
					boxIssues[ln.LoadUnitID] = bi
				}
				bi.foreign = bi.foreign || m.Discrepancy == model.CZDiscrepancyForeignMark
				bi.retired = bi.retired || m.Discrepancy == model.CZDiscrepancyRetired
				continue
			}
			k := problemKey{line: i, reason: m.Discrepancy}
			if _, ok := loose[k]; !ok {
				looseKeys = append(looseKeys, k)
			}
			loose[k] = append(loose[k], m.CIS)
		}
	}
	if len(boxIssues) == 0 && len(looseKeys) == 0 {
		return nil
	}

	isolator, err := isolatorWarehouse(ctx, q)
	if err != nil {
		return err
	}
	base := ProblemSubmitInput{
		WarehouseID: in.WarehouseID, CreatedBy: in.CreatedBy, ToInternalWarehouseID: isolator,
		fromIntake: true,
	}
	// Короба - в порядке ГЕ прихода: номер проблемы не должен зависеть от обхода словаря.
	for _, lu := range in.LoadUnits {
		bi := boxIssues[lu.ID]
		if bi == nil {
			continue
		}
		p := base
		p.ProblemID, p.LoadUnitID, p.Mark = uuid.NewString(), lu.ID, lu.CZCode
		p.Reason = model.ProblemReasonRetired
		if bi.foreign {
			p.Reason = model.ProblemReasonForeignMark
		}
		// Марки короба запоминают проблему в problemSubmit (CZ-06).
		if err := problemSubmit(ctx, q, p); err != nil {
			return err
		}
	}
	for _, k := range looseKeys {
		ln, cis := in.Lines[k.line], loose[k]
		p := base
		p.ProblemID, p.Reason = uuid.NewString(), k.reason
		p.GoodID, p.ProductionDate, p.Qty = ln.GoodID, ln.ProductionDate, decimal.NewFromInt(int64(len(cis)))
		if ln.LoadUnitID != "" {
			p.FromLoadUnitID = ln.LoadUnitID
		} else {
			p.CellID = ln.CellID
		}
		if len(cis) == 1 {
			p.Mark = cis[0]
		}
		// Марки уходят в россыпь «Изолятора» той же ячейки вместе с товаром - общим путём
		// пометки проблемы марками (CZ-06).
		p.Marks = cis
		if err := problemSubmit(ctx, q, p); err != nil {
			return err
		}
		if ln.LoadUnitID == "" && in.ReceiptID != "" {
			if err := excludeFromPutawayTask(ctx, q, in.ReceiptID, p.CellID, p.GoodID, p.ProductionDate, p.Qty); err != nil {
				return err
			}
		}
	}
	return nil
}

// receiptCZIntake - приход ЧЗ проведённой приёмки. [cells] - ячейка каждой строки после
// подстановки ячейки приёмки.
func receiptCZIntake(in ReceiptSubmitInput, cells []string) CZIntakeInput {
	lines := make([]model.ReceiptLineInput, len(in.Lines))
	for i, ln := range in.Lines {
		ln.CellID = cells[i]
		lines[i] = ln
	}
	return CZIntakeInput{
		ReceiptID: in.ReceiptID, WarehouseID: in.WarehouseID, CreatedBy: in.CreatedBy,
		LoadUnits: in.LoadUnits, Lines: lines, CZGroups: in.CZGroups,
	}
}

// problemKey - проблема марок россыпью: строка прихода и причина.
type problemKey struct {
	line   int
	reason string
}

// isolatorWarehouse - id «Изолятора». Нет его (удалён или переименован код) - отказ: товар
// с расхождением завести на «Основной» как обычный нельзя.
func isolatorWarehouse(ctx context.Context, q Querier) (string, error) {
	var id string
	err := q.QueryRow(ctx, `SELECT id::text FROM internal_warehouses WHERE code = $1`, isolatorCode).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", model.ErrUnknownInternalWarehouse
	}
	if err != nil {
		return "", fmt.Errorf("склад «Изолятор»: %w", err)
	}
	return id, nil
}
