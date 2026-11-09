// Package picking — подбор источников для заказа сборки (P9-03).
//
// Что: по строкам плана заказа решает, откуда брать товар — какая партия, какая ячейка, россыпь
// или короб хранения и сколько из каждого. Правила — docs/picking.md, «Подбор»: партия и ячейка
// реестра — основа, а не подсказка; альтернатива WMS появляется, только когда реестр не
// выполним (партии нет в остатке — FEFO, в ячейке реестра нет товара — ячейка WMS).
//
// Зачем отдельный пакет: подбор — чистое правило над остатком, без БД и HTTP. Его зовут и выдача
// заказа на ТСД (P9-04), и повторный подбор после пика или правки реестра; тестируется таблицей.
//
// Резерва нет (вопрос №9 закрыт 2026-11-08): доступное источника — остаток минус открытые пики
// всех заказов на момент запроса. Два заказа, подобранные одновременно, могут получить один и тот
// же источник; кто первым пикнет — тот и взял, второму следующий подбор покажет другой источник
// или нехватку. Окончательно остаток проверяет сам пик (P9-05).
package picking

import (
	"sort"
	"time"

	"github.com/shopspring/decimal"
)

// Source — откуда можно взять товар: россыпь ячейки (LoadUnitID пуст) или короб хранения в ней.
// Available — остаток источника минус «в сборке» (открытые пики), всегда > 0.
type Source struct {
	CellID              string
	CellAddress         string
	IsFloorStorage      bool
	LoadUnitID          string
	InternalWarehouseID string
	GoodID              string
	BatchID             string
	BatchDate           time.Time
	Available           decimal.Decimal
}

// Line — строка плана заказа для подбора. BatchDate и CellID — партия и ячейка реестра (nil —
// не указаны или ячейки нет в WMS). Taken — уже взято по строке (открытые и перенесённые в короб
// пики): подбирается только разница.
type Line struct {
	ID           string
	GoodID       string
	BatchDate    *time.Time
	CellID       *string
	RegistryCell string
	PlanQty      decimal.Decimal
	Taken        decimal.Decimal
}

// Take — сколько взять из одного источника.
type Take struct {
	Source Source
	Qty    decimal.Decimal
}

// Suggestion — подбор одной строки.
//
// Remaining — сколько ещё собрать; Short — сколько не покрыто доступным остатком.
// BatchSubstituted — хотя бы часть идёт не из партии реестра (её нет или не хватает) — FEFO.
// CellSubstituted — у строки есть ячейка реестра, но хотя бы часть идёт из другой ячейки: ТСД
// показывает ячейку WMS, а ячейку реестра — рядом серым в скобках (RegistryCell).
type Suggestion struct {
	LineID           string
	Remaining        decimal.Decimal
	Takes            []Take
	Short            decimal.Decimal
	BatchSubstituted bool
	CellSubstituted  bool
	RegistryCell     string
}

// SuggestOrder подбирает источники всем строкам заказа.
//
// Как: доступное каждого источника — общее на заказ, поэтому строка, взявшая источник, уменьшает
// его для следующих строк — две строки одного товара не получают один и тот же остаток дважды.
// Сначала подбираются строки с партией реестра (им нужна именно она), затем строки без партии —
// FEFO по тому, что осталось. Результат — в порядке строк на входе.
//
// sources — источники товаров заказа; порядок не важен, функция упорядочивает сама.
func SuggestOrder(lines []Line, sources []Source) []Suggestion {
	pool := make([]Source, len(sources))
	copy(pool, sources)

	byGood := map[string][]int{}
	for i, s := range pool {
		byGood[s.GoodID] = append(byGood[s.GoodID], i)
	}

	order := make([]int, len(lines))
	for i := range order {
		order[i] = i
	}
	// Строки с партией реестра — первыми; внутри групп порядок файла сохраняется.
	sort.SliceStable(order, func(a, b int) bool {
		return lines[order[a]].BatchDate != nil && lines[order[b]].BatchDate == nil
	})

	out := make([]Suggestion, len(lines))
	for _, i := range order {
		out[i] = suggestLine(lines[i], pool, byGood[lines[i].GoodID])
	}
	return out
}

// suggestLine подбирает одну строку жадно по упорядоченным источникам её товара и списывает
// взятое из pool.
func suggestLine(ln Line, pool []Source, idx []int) Suggestion {
	sg := Suggestion{LineID: ln.ID, RegistryCell: ln.RegistryCell}
	sg.Remaining = ln.PlanQty.Sub(ln.Taken)
	if !sg.Remaining.IsPositive() {
		sg.Remaining = decimal.Zero
		return sg
	}

	cand := make([]int, len(idx))
	copy(cand, idx)
	sort.SliceStable(cand, func(a, b int) bool { return sourceLess(ln, pool[cand[a]], pool[cand[b]]) })

	need := sg.Remaining
	for _, i := range cand {
		if !need.IsPositive() {
			break
		}
		src := &pool[i]
		if !src.Available.IsPositive() {
			continue
		}
		qty := decimal.Min(need, src.Available)
		sg.Takes = append(sg.Takes, Take{Source: *src, Qty: qty})
		src.Available = src.Available.Sub(qty)
		need = need.Sub(qty)

		if ln.BatchDate != nil && !src.BatchDate.Equal(*ln.BatchDate) {
			sg.BatchSubstituted = true
		}
		if ln.RegistryCell != "" && (ln.CellID == nil || src.CellID != *ln.CellID) {
			sg.CellSubstituted = true
		}
	}
	sg.Short = need
	return sg
}

// sourceLess — порядок источников строки:
//  1. партия реестра, затем остальные партии по дате производства (FEFO);
//  2. внутри партии — ячейка реестра;
//  3. россыпь раньше короба: не вскрывать лишний короб, пока товар лежит открыто;
//  4. больше доступного — раньше: меньше остановок у ячеек;
//  5. адрес, затем короб — чтобы подбор был одинаковым при одинаковом остатке.
//
// Напольное хранение (`*-Н-П`) идёт наравне с ячейками стеллажей: из него собирать разрешено.
func sourceLess(ln Line, a, b Source) bool {
	if ln.BatchDate != nil {
		ra, rb := a.BatchDate.Equal(*ln.BatchDate), b.BatchDate.Equal(*ln.BatchDate)
		if ra != rb {
			return ra
		}
	}
	if !a.BatchDate.Equal(b.BatchDate) {
		return a.BatchDate.Before(b.BatchDate)
	}
	if ln.CellID != nil {
		ra, rb := a.CellID == *ln.CellID, b.CellID == *ln.CellID
		if ra != rb {
			return ra
		}
	}
	if la, lb := a.LoadUnitID == "", b.LoadUnitID == ""; la != lb {
		return la
	}
	if c := a.Available.Cmp(b.Available); c != 0 {
		return c > 0
	}
	if a.CellAddress != b.CellAddress {
		return a.CellAddress < b.CellAddress
	}
	return a.LoadUnitID < b.LoadUnitID
}
