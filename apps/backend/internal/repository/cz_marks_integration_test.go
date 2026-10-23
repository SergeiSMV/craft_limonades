package repository_test

import (
	"context"
	"errors"
	"testing"

	"github.com/google/uuid"

	"craftwms/internal/model"
	"craftwms/internal/repository"
)

// Марки и агрегаты ЧЗ (CZ-03): критерий задачи — марка и агрегат хранятся с привязкой к месту
// на складе. Одна база на все случаи (фикстура setupStock), коды у случаев свои.
// КИ и SSCC — по образцу живого короба пива, прочитанного на проде в CZ-02.
func TestCZMarks(t *testing.T) {
	fx := setupStock(t)
	ctx := context.Background()
	repo := repository.NewCZMarkRepository(fx.pool)

	// placedBox — ГЕ короба, размещённая в ячейке A.
	placedBox := func(t *testing.T) string {
		t.Helper()
		lu := newLU(t, fx, "box")
		if _, err := fx.pool.Exec(ctx,
			`UPDATE load_units SET cell_id = $2::uuid, status = 'placed' WHERE id = $1::uuid`, lu, fx.cellA); err != nil {
			t.Fatalf("разместить ГЕ: %v", err)
		}
		return lu
	}
	inBox := func(cis, lu, agg string) model.CZMark {
		return model.CZMark{CIS: cis, GoodID: fx.good, BatchID: fx.batch, LoadUnitID: lu, AggregateCode: agg}
	}

	t.Run("короб ЧЗ — ГЕ с составом", func(t *testing.T) {
		lu := placedBox(t)
		box := model.CZAggregate{Code: "00146801691100407293", Kind: model.CZAggregateBox, LoadUnitID: lu}
		group := model.CZAggregate{Code: "0104612728200189215grp001", Kind: model.CZAggregateGroup, ParentCode: box.Code}
		marks := []model.CZMark{
			inBox("0104612728200172215AmxPmd", lu, box.Code),
			inBox("0104612728200172215>!jNgg", lu, group.Code),
			inBox(`0104612728200172215D"nZZl`, lu, group.Code),
		}
		if err := repo.ReceiveBox(ctx, box, []model.CZAggregate{group}, marks); err != nil {
			t.Fatal(err)
		}

		// Скан SSCC находит ГЕ без QR-ярлыка.
		if got, err := repo.LoadUnitByCZCode(ctx, box.Code); err != nil || got != lu {
			t.Fatalf("ГЕ по SSCC = %q, %v; want %s", got, err, lu)
		}
		// Марка знает товар, партию, GTIN и место — ячейку своего короба.
		m, err := repo.MarkByCIS(ctx, "0104612728200172215>!jNgg")
		if err != nil {
			t.Fatal(err)
		}
		if m.GTIN != "04612728200172" || m.Status != model.CZMarkInStock || m.LoadUnitID != lu ||
			m.LoadUnitCellID != fx.cellA || m.CellAddress == "" || m.CellID != "" || m.AggregateCode != group.Code ||
			m.GoodID != fx.good || m.BatchID != fx.batch || m.ReceivedAt.IsZero() {
			t.Fatalf("марка = %+v", m)
		}
		if got, err := repo.MarksOfLoadUnit(ctx, lu); err != nil || len(got) != 3 {
			t.Fatalf("марки короба: %d, %v", len(got), err)
		}
		// Состав по ЧЗ: в коробе — упаковка и одна марка напрямую, в упаковке — две марки.
		bc, err := repo.AggregateContents(ctx, box.Code)
		if err != nil {
			t.Fatal(err)
		}
		if bc.Aggregate.LoadUnitID != lu || bc.Aggregate.OpenedAt != nil || len(bc.Groups) != 1 || len(bc.Marks) != 1 {
			t.Fatalf("состав короба: %+v", bc)
		}
		gc, err := repo.AggregateContents(ctx, group.Code)
		if err != nil {
			t.Fatal(err)
		}
		if gc.Aggregate.ParentCode != box.Code || len(gc.Groups) != 0 || len(gc.Marks) != 2 {
			t.Fatalf("состав упаковки: %+v", gc)
		}
	})

	t.Run("марка россыпью в ячейке", func(t *testing.T) {
		loose := model.CZMark{CIS: "0104612728200172215loose01", GoodID: fx.good, BatchID: fx.batch,
			CellID: fx.cellB, InternalWarehouseID: fx.iwh}
		if err := repo.SaveMarks(ctx, []model.CZMark{loose}); err != nil {
			t.Fatal(err)
		}
		got, err := repo.LooseMarksOfCell(ctx, fx.cellB)
		if err != nil || len(got) != 1 || got[0].CIS != loose.CIS || got[0].LoadUnitID != "" ||
			got[0].InternalWarehouseID != fx.iwh {
			t.Fatalf("россыпь ячейки: %+v, %v", got, err)
		}
	})

	t.Run("короб принимается целиком или никак", func(t *testing.T) {
		lu := placedBox(t)
		box := model.CZAggregate{Code: "00146801691100400001", Kind: model.CZAggregateBox, LoadUnitID: lu}
		bad := model.CZMark{CIS: "0104612728200172215nowhere", GoodID: fx.good, BatchID: fx.batch} // без места
		err := repo.ReceiveBox(ctx, box, nil, []model.CZMark{inBox("0104612728200172215atomic1", lu, box.Code), bad})
		if err == nil {
			t.Fatal("марка без места принята")
		}
		if _, err := repo.LoadUnitByCZCode(ctx, box.Code); !errors.Is(err, model.ErrCZAggregateNotFound) {
			t.Fatalf("короб остался после отката: %v", err)
		}
		if _, err := repo.MarkByCIS(ctx, "0104612728200172215atomic1"); !errors.Is(err, model.ErrCZMarkNotFound) {
			t.Fatalf("марка осталась после отката: %v", err)
		}
	})

	t.Run("марка и короб уникальны", func(t *testing.T) {
		err := repo.SaveMarks(ctx, []model.CZMark{inBox("0104612728200172215AmxPmd", placedBox(t), "")})
		if !errors.Is(err, model.ErrCZMarkExists) {
			t.Fatalf("повтор марки: %v", err)
		}
		again := model.CZAggregate{Code: "00146801691100407293", Kind: model.CZAggregateBox, LoadUnitID: placedBox(t)}
		if err := repo.ReceiveBox(ctx, again, nil, nil); !errors.Is(err, model.ErrCZAggregateExists) {
			t.Fatalf("повтор короба: %v", err)
		}
	})

	t.Run("место марки — ровно одно", func(t *testing.T) {
		lu := placedBox(t)
		twoPlaces := model.CZMark{CIS: "0104612728200172215twoplac", GoodID: fx.good, BatchID: fx.batch,
			LoadUnitID: lu, CellID: fx.cellA, InternalWarehouseID: fx.iwh}
		if err := repo.SaveMarks(ctx, []model.CZMark{twoPlaces}); err == nil {
			t.Fatal("марка в двух местах принята")
		}
		shipped := model.CZMark{CIS: "0104612728200172215shipped", GoodID: fx.good, BatchID: fx.batch,
			Status: model.CZMarkShipped}
		if err := repo.SaveMarks(ctx, []model.CZMark{shipped}); err != nil {
			t.Fatalf("отгруженная марка без места: %v", err)
		}
	})

	t.Run("не найдено", func(t *testing.T) {
		if _, err := repo.MarkByCIS(ctx, "0104612728200172215unknown"); !errors.Is(err, model.ErrCZMarkNotFound) {
			t.Fatalf("марка: %v", err)
		}
		// Групповая упаковка — не ГЕ: по её коду ГЕ не найти.
		if _, err := repo.LoadUnitByCZCode(ctx, "0104612728200189215grp001"); !errors.Is(err, model.ErrCZAggregateNotFound) {
			t.Fatalf("ГЕ по коду упаковки: %v", err)
		}
		if _, err := repo.AggregateContents(ctx, "00999999999999999999"); !errors.Is(err, model.ErrCZAggregateNotFound) {
			t.Fatalf("состав: %v", err)
		}
	})

	t.Run("товар по GTIN через ШК", func(t *testing.T) {
		if _, err := fx.pool.Exec(ctx,
			`INSERT INTO barcodes (good_id, barcode) VALUES ($1::uuid, '4612728200172')`, fx.good); err != nil {
			t.Fatalf("ШК: %v", err)
		}
		if got, err := repo.GoodByGTIN(ctx, "04612728200172"); err != nil || got.ID != fx.good || got.Name == "" {
			t.Fatalf("товар по GTIN = %+v, %v", got, err)
		}
		if _, err := repo.GoodByGTIN(ctx, "04600000000000"); !errors.Is(err, model.ErrCZUnknownGTIN) {
			t.Fatalf("чужой GTIN: %v", err)
		}
	})
}

// CZ-05: признак «маркируемый» — в справочнике и поиске по ШК, правка admin, привязка ШК из
// марки ставит его сама (долг 16, признак по факту).
func TestCZGoodMarked(t *testing.T) {
	fx := setupStock(t)
	ctx := context.Background()
	repo := repository.NewCZMarkRepository(fx.pool)
	goods := repository.NewGoodsRepository(fx.pool)
	marked := func() bool {
		t.Helper()
		g, err := goods.GetByID(ctx, fx.good)
		if err != nil {
			t.Fatal(err)
		}
		return g.CZMarked
	}

	if marked() {
		t.Fatal("новый товар уже маркируемый")
	}
	if err := repo.SetGoodCZMarked(ctx, fx.good, true); err != nil || !marked() {
		t.Fatalf("правка: %v", err)
	}
	if err := repo.SetGoodCZMarked(ctx, fx.good, false); err != nil || marked() {
		t.Fatalf("снятие: %v", err)
	}
	if err := repo.SetGoodCZMarked(ctx, "00000000-0000-4000-8000-000000000999", true); !errors.Is(err, model.ErrCZGoodNotFound) {
		t.Fatalf("нет товара: %v", err)
	}

	// Обычная привязка ШК признак не ставит, привязка из марки — ставит.
	ops := repository.NewOperationsRepository(fx.pool)
	if _, err := ops.BindBarcode(ctx, uuid.NewString(), repository.BarcodeBindInput{
		GoodID: fx.good, Barcode: "4600000000017"}); err != nil || marked() {
		t.Fatalf("обычная привязка: %v, marked=%v", err, marked())
	}
	if _, err := ops.BindBarcode(ctx, uuid.NewString(), repository.BarcodeBindInput{
		GoodID: fx.good, Barcode: "4612728200172", FromCZMark: true}); err != nil || !marked() {
		t.Fatalf("привязка из марки: %v, marked=%v", err, marked())
	}
	// Поиск по ШК отдаёт признак: по нему приёмка просит скан марки.
	g, err := repository.NewBarcodeRepository(fx.pool).GetGoodByBarcode(ctx, "4612728200172")
	if err != nil || !g.CZMarked {
		t.Fatalf("товар по ШК: %+v, %v", g, err)
	}
}
