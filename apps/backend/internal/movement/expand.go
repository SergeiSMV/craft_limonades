// Package movement — разворот складских движений в товарные строки (P4-09-1).
//
// Что: операции склада двигают грузовые единицы («короб X из ячейки A в ячейку B») и россыпь,
// а документы для 1С говорят товарами: товар · партия · откуда · куда · количество. 1С про
// короба не знает ничего. Здесь движение по ГЕ раскладывается по её составу, россыпь проходит
// как есть, одинаковые строки складываются.
//
// Зачем отдельный пакет: разворот общий для всех отчётов с движением — «Поступление» (P4-10),
// «Движение» размещения (P5-04), перемещения и пополнения (P6-07). Три своих разворота
// разошлись бы в правилах агрегации и вложенности.
//
// Пакет не знает ни про БД, ни про HTTP: состав ГЕ ему подаёт ContentReader. Состав
// обязан читаться на момент операции, внутри её транзакции, и уходить в снимок документа
// (P3-01): документ о перемещении, открытый через неделю, должен показать то, что реально
// переехало, а не нынешнее содержимое короба.
package movement

import (
	"context"
	"errors"
	"fmt"

	"github.com/shopspring/decimal"
)

// Ошибки разворота.
var (
	// ErrInvalidMove — движение не описывает ни ГЕ, ни товар с партией и количеством, либо
	// описывает и то и другое сразу.
	ErrInvalidMove = errors.New("move must be either a load unit or a good with batch and positive qty")
	// ErrLoadUnitNotFound — движение ссылается на ГЕ, которой нет.
	ErrLoadUnitNotFound = errors.New("load unit not found")
)

// Move — одно движение операции: ГЕ целиком либо россыпь.
//
// Ячейки пустые там, где их у операции нет: у прихода нет «откуда», у отгрузки (P9) — «куда».
type Move struct {
	FromCellID string
	ToCellID   string

	// LoadUnitID — движется ГЕ целиком; товар, партия и количество тогда пусты.
	LoadUnitID string

	// Россыпь: товар, партия и количество; LoadUnitID тогда пуст.
	GoodID  string
	BatchID string
	Qty     decimal.Decimal
}

// ContentLine — позиция состава ГЕ: товар · партия · количество.
type ContentLine struct {
	GoodID  string
	BatchID string
	Qty     decimal.Decimal
}

// ContentReader — источник состава ГЕ.
//
// Contents возвращает состав каждой из запрошенных ГЕ, ВКЛЮЧАЯ вложенные (паллета с
// коробами — это всё, что в коробах). Ключ есть у каждой существующей ГЕ, даже пустой
// (тогда срез пуст); отсутствие ключа означает, что такой ГЕ нет.
type ContentReader interface {
	Contents(ctx context.Context, loadUnitIDs []string) (map[string][]ContentLine, error)
}

// Line — товарная строка движения, как её увидит документ.
type Line struct {
	GoodID     string
	BatchID    string
	FromCellID string
	ToCellID   string
	Qty        decimal.Decimal
}

// lineKey — грань агрегации: одинаковые товар, партия и ячейки складываются.
type lineKey struct {
	good, batch, from, to string
}

// Expand разворачивает движения в товарные строки и агрегирует их.
//
// Правила:
//   - ГЕ раскладывается по составу (вместе с вложенными ГЕ);
//   - россыпь проходит как есть;
//   - строки с одинаковыми товаром, партией и ячейками складываются: три короба одного
//     товара одной партии, переехавшие в одну ячейку, дают одну строку. 1С короба не
//     различает, и три одинаковые строки были бы для оператора шумом;
//   - строки с нулевым итогом отбрасываются — по ним ничего не переехало (пустая позиция
//     в составе ГЕ);
//   - порядок строк — порядок первого появления грани: документ читается в том порядке,
//     в каком кладовщик работал, и от запуска к запуску не скачет.
//
// Одна и та же ГЕ в двух движениях разворачивается дважды: это два разных движения
// (например, A→B и B→C), и склеивать их — дело вызывающего.
func Expand(ctx context.Context, moves []Move, content ContentReader) ([]Line, error) {
	luIDs := make([]string, 0)
	seen := map[string]bool{}
	for i, m := range moves {
		if err := validate(m); err != nil {
			return nil, fmt.Errorf("движение %d: %w", i, err)
		}
		if m.LoadUnitID != "" && !seen[m.LoadUnitID] {
			seen[m.LoadUnitID] = true
			luIDs = append(luIDs, m.LoadUnitID)
		}
	}

	// Состав всех ГЕ — одним обращением, а не по запросу на ГЕ: операция может нести
	// десятки коробов, и N запросов внутри транзакции держали бы её дольше нужного.
	var contents map[string][]ContentLine
	if len(luIDs) > 0 {
		var err error
		contents, err = content.Contents(ctx, luIDs)
		if err != nil {
			return nil, fmt.Errorf("состав ГЕ: %w", err)
		}
	}

	agg := newAggregator()
	for _, m := range moves {
		if m.LoadUnitID == "" {
			agg.add(m.GoodID, m.BatchID, m.FromCellID, m.ToCellID, m.Qty)
			continue
		}
		lines, ok := contents[m.LoadUnitID]
		if !ok {
			return nil, fmt.Errorf("%w: %s", ErrLoadUnitNotFound, m.LoadUnitID)
		}
		for _, c := range lines {
			agg.add(c.GoodID, c.BatchID, m.FromCellID, m.ToCellID, c.Qty)
		}
	}
	return agg.lines(), nil
}

// validate проверяет, что движение — ровно одно из двух: ГЕ или россыпь.
func validate(m Move) error {
	isLU := m.LoadUnitID != ""
	hasGood := m.GoodID != "" || m.BatchID != "" || !m.Qty.IsZero()
	switch {
	case isLU && hasGood:
		return ErrInvalidMove
	case isLU:
		return nil
	case m.GoodID == "" || m.BatchID == "" || !m.Qty.IsPositive():
		return ErrInvalidMove
	default:
		return nil
	}
}

// aggregator складывает строки по грани, сохраняя порядок первого появления.
type aggregator struct {
	order []lineKey
	sums  map[lineKey]decimal.Decimal
}

func newAggregator() *aggregator {
	return &aggregator{sums: map[lineKey]decimal.Decimal{}}
}

func (a *aggregator) add(good, batch, from, to string, qty decimal.Decimal) {
	k := lineKey{good: good, batch: batch, from: from, to: to}
	if _, ok := a.sums[k]; !ok {
		a.order = append(a.order, k)
	}
	a.sums[k] = a.sums[k].Add(qty)
}

func (a *aggregator) lines() []Line {
	out := make([]Line, 0, len(a.order))
	for _, k := range a.order {
		q := a.sums[k]
		if q.IsZero() {
			continue
		}
		out = append(out, Line{GoodID: k.good, BatchID: k.batch, FromCellID: k.from, ToCellID: k.to, Qty: q})
	}
	return out
}
