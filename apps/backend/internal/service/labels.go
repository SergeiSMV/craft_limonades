package service

import (
	"context"
	"errors"
	"regexp"
	"sort"
	"strconv"

	"github.com/google/uuid"

	"craftwms/internal/labels"
	"craftwms/internal/model"
	"craftwms/internal/repository"
)

// warehouseCodeRepo — резолв склада по коду (для ?warehouse=SHB).
type warehouseCodeRepo interface {
	IDByCode(ctx context.Context, code string) (string, error)
}

// cellLabelRepo — ячейки склада с настройками этикеток и стеллажи (то же, что видит страница).
type cellLabelRepo interface {
	Setup(ctx context.Context, warehouseID string) ([]model.CellSetup, []model.Rack, error)
}

// Виды PDF — те же три файла, что собирал rack_labels.
const (
	LabelKindLarge = "large" // этикетки на большую балку, 4 на лист
	LabelKindSmall = "small" // этикетки на малую балку, 6 на лист
	LabelKindCards = "cards" // карточки на боковую опору стеллажа, 2 на лист
)

// ErrUnknownLabelKind — вид PDF не large, small или cards.
var ErrUnknownLabelKind = errors.New("вид этикеток: large, small или cards")

// LabelService — PDF этикеток ячеек и карточек на стойку по геометрии rack_labels (ADHOC-57).
type LabelService struct {
	warehouses warehouseCodeRepo
	cells      cellLabelRepo
}

// NewLabelService собирает сервис этикеток.
func NewLabelService(warehouses warehouseCodeRepo, cells cellLabelRepo) *LabelService {
	return &LabelService{warehouses: warehouses, cells: cells}
}

// CellLabelsPDF — PDF вида kind по выбранным ячейкам склада и имя файла.
//
// cellIDs пуст — весь склад. Иначе печатаются только выбранные: на балку — ячейки своего
// размера, карточки — стеллажей выбранных ячеек с галочкой «карточка», и каждая карточка
// целиком, со всеми ячейками стеллажа (половина карточки на стойке бесполезна).
// Кегль считается по всему складу, а не по выборке: перепечатанная этикетка обязана совпасть
// с соседними на стеллаже.
//
// Ошибки: repository.ErrNotFound — нет склада; ErrUnknownLabelKind, ErrInvalidCellIDs;
// repository.ErrForeignCells — среди id есть ячейка не этого склада (или приёмки);
// labels.ErrNothingToPrint — в выборке нет этикеток этого вида; *labels.FitError — не влезает.
func (s *LabelService) CellLabelsPDF(ctx context.Context, warehouseCode, kind string, cellIDs []string) ([]byte, string, error) {
	if kind != LabelKindLarge && kind != LabelKindSmall && kind != LabelKindCards {
		return nil, "", ErrUnknownLabelKind
	}
	for _, id := range cellIDs {
		if _, err := uuid.Parse(id); err != nil {
			return nil, "", ErrInvalidCellIDs
		}
	}
	whID, err := s.warehouses.IDByCode(ctx, warehouseCode)
	if err != nil {
		return nil, "", err
	}
	cells, _, err := s.cells.Setup(ctx, whID)
	if err != nil {
		return nil, "", err
	}
	sort.Slice(cells, func(i, j int) bool { return cellBefore(cells[i], cells[j]) })

	selected := make([]model.CellSetup, 0, len(cells))
	if len(cellIDs) == 0 {
		selected = cells
	} else {
		want := map[string]bool{}
		for _, id := range cellIDs {
			want[id] = true
		}
		for _, c := range cells {
			if want[c.ID] {
				selected = append(selected, c)
				delete(want, c.ID)
			}
		}
		if len(want) > 0 {
			return nil, "", repository.ErrForeignCells
		}
	}

	if kind == LabelKindCards {
		pdf, err := labels.SideCards(sideCards(cells, selected))
		return pdf, "side_cards.pdf", err
	}
	small := kind == LabelKindSmall
	var items, set []labels.Cell
	for _, c := range cells {
		if c.LabelSmall == small {
			set = append(set, beamCell(c))
		}
	}
	for _, c := range selected {
		if c.LabelSmall == small {
			items = append(items, beamCell(c))
		}
	}
	pdf, err := labels.BeamLabels(small, items, set)
	return pdf, "labels_" + kind + ".pdf", err
}

// beamCell — этикетка ячейки. Напольная (ADHOC-61) — всегда с QR: адрес кириллицей Code128 не
// кодирует, а без кода ячейку на ТСД не отсканировать; галочка штрих-кода её не касается.
func beamCell(c model.CellSetup) labels.Cell {
	if c.IsFloorStorage {
		return labels.Cell{Address: c.Address, IsFloor: c.IsFloor, QR: true}
	}
	return labels.Cell{Address: c.Address, IsFloor: c.IsFloor, Barcode: c.LabelBarcode}
}

// sideCards — карточки стеллажей выбранных ячеек и адреса всех карточек склада для единого
// кегля. Решение 2026-11-05: галочка «на карточке» — у ячейки, стеллаж только группирует. Карточку
// печатает выбранная ячейка с галочкой и стеллажом; строки карточки — все ячейки её стеллажа с
// галочкой (штрих-код на балке не учитывается — что сканировать с карточки, решает человек).
// Строки карточки — позиции убывают, ярусы сверху вниз: так стеллаж выглядит из прохода, если
// клеить карточку на правую опору (как в rack_labels).
func sideCards(cells []model.CellSetup, selected []model.CellSetup) ([]labels.Card, []string) {
	onCard := func(c model.CellSetup) bool { return c.SideCard && c.RackID != nil && c.RackCode != nil }
	rows := map[string][]model.CellSetup{}
	var set []string
	for _, c := range cells {
		if onCard(c) {
			rows[*c.RackID] = append(rows[*c.RackID], c)
			set = append(set, c.Address)
		}
	}
	var cards []labels.Card
	seen := map[string]bool{}
	for _, c := range selected { // порядок выборки — порядок стеллажей
		if !onCard(c) || seen[*c.RackID] {
			continue
		}
		seen[*c.RackID] = true
		rs := rows[*c.RackID]
		sort.SliceStable(rs, func(i, j int) bool {
			ti, pi := tierPos(rs[i].Address)
			tj, pj := tierPos(rs[j].Address)
			if pi != pj {
				return pi > pj
			}
			return ti > tj
		})
		card := labels.Card{Rack: *c.RackCode}
		for _, r := range rs {
			_, pos := tierPos(r.Address)
			card.Rows = append(card.Rows, labels.CardRow{Address: r.Address, Position: pos})
		}
		cards = append(cards, card)
	}
	return cards, set
}

// tierPosRe — ярус и позиция — два последних числа адреса («B-1-3-12» — ярус 3, позиция 12).
var tierPosRe = regexp.MustCompile(`-(\d+)-(\d+)$`)

// tierPos — ярус и позиция ячейки; адрес другого вида — нули (ячейка уходит в конец порядка).
func tierPos(address string) (tier, pos int) {
	m := tierPosRe.FindStringSubmatch(address)
	if m == nil {
		return 0, 0
	}
	tier, _ = strconv.Atoi(m[1])
	pos, _ = strconv.Atoi(m[2])
	return tier, pos
}

// cellBefore — порядок наклейки этикеток на балки: по стеллажу (без стеллажа — в конце), внутри
// стеллажа по позиции слева направо, в позиции ярусы сверху вниз — в этом порядке клеящий идёт
// вдоль стеллажа. При равенстве — натуральный порядок адресов.
func cellBefore(a, b model.CellSetup) bool {
	switch {
	case a.RackCode == nil && b.RackCode != nil:
		return false
	case a.RackCode != nil && b.RackCode == nil:
		return true
	case a.RackCode != nil && *a.RackCode != *b.RackCode:
		return naturalLess(*a.RackCode, *b.RackCode)
	}
	ta, pa := tierPos(a.Address)
	tb, pb := tierPos(b.Address)
	if pa != pb {
		return pa < pb
	}
	if ta != tb {
		return ta > tb
	}
	return naturalLess(a.Address, b.Address)
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
