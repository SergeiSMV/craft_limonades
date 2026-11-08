package report

import (
	"bytes"
	"fmt"
	"strings"
	"time"

	"github.com/xuri/excelize/v2"

	"craftwms/internal/model"
)

// Листы выгрузки «Сборка-отгрузка» (P8-03): «Сборка» — заказы блоками с позициями, как в окне
// деталей портала; «Заказы» — строка на заказ для сверки; «Правки» — правки реестра.
const (
	pickingMainSheet    = "Сборка"
	pickingOrdersSheet  = "Заказы"
	pickingChangesSheet = "Правки"
)

var (
	pickingLineHeaders = []string{
		"№", "Код", "Наименование", "Ед.", "Ячейка по реестру", "Партия по реестру", "План", "Факт",
		"Партия факта", "Ячейка факта", "Короб", "Кол-во", "Комментарий", "Марка ЧЗ",
	}
	// Ширины колонок листа «Сборка» в символах, по порядку заголовков.
	pickingLineWidths = []float64{5, 14, 44, 6, 16, 16, 8, 8, 14, 14, 8, 8, 36, 34}

	pickingOrderHeaders = []string{
		"Сборка", "Накладная", "Заказ", "Дата заказа", "Клиент", "Направление", "Адрес",
		"Статус", "Пометки", "В работе у", "Собрал", "Строк", "План", "Факт", "Коробов",
	}
	pickingChangeHeaders = []string{
		"Сборка", "Накладная", "Заказ", "Когда", "Правка", "Код", "Наименование", "Партия",
		"Было", "Стало", "Статус заказа",
	}
)

// PickingStatusTitle — статус заказа сборки для человека; незнакомый — как есть.
func PickingStatusTitle(status string) string {
	switch status {
	case model.PickingStatusNew:
		return "новый"
	case model.PickingStatusInProgress:
		return "в работе"
	case model.PickingStatusPicked:
		return "собран"
	case model.PickingStatusShipped:
		return "отгружен"
	default:
		return status
	}
}

// pickingChangeTitle — вид правки реестра для человека.
func pickingChangeTitle(kind string) string {
	switch kind {
	case model.PickingChangeLineAdded:
		return "добавлена строка"
	case model.PickingChangeLineRemoved:
		return "убрана строка"
	case model.PickingChangeQtyChanged:
		return "изменено количество"
	case model.PickingChangeOrderDeleted:
		return "заказ удалён в 1С"
	case model.PickingChangeOrderRestored:
		return "заказ вернулся в реестр"
	default:
		return kind
	}
}

// pickingFlags — пометки заказа одной ячейкой: «собран частично», «нераспознанные позиции»…
func pickingFlags(o model.PickingPortalOrder) string {
	var flags []string
	if o.IsPartial {
		flags = append(flags, "собран частично")
	}
	if o.HasUnknown {
		flags = append(flags, "нераспознанные позиции")
	}
	if o.Deleted {
		flags = append(flags, "удалён в 1С")
	}
	if o.ChangedAfterShipment {
		flags = append(flags, "изменён в 1С после отгрузки")
	}
	return strings.Join(flags, ", ")
}

// BuildPickingXLSX собирает выгрузку «Сборка-отгрузка» за дату накладной date (P8-03).
//
// Что: все заказы даты на момент выгрузки — статус WMS и то же, что в окне деталей портала.
// Зачем: простое скачивание для офиса, не документ для «Провести»: в 1С по нему ничего не
// проводится. Как: лист «Сборка» — заказ блоком (шапка построчно с подписями, затем позиции с
// заголовком колонок), позиция — план реестра и факт склада; факт по партии, ячейке и коробу —
// своей строкой, марка ЧЗ — своей строкой под фактом. Листы «Заказы» и «Правки» — для сверки
// и фильтров.
func BuildPickingXLSX(date time.Time, orders []model.PickingPortalDetail) ([]byte, error) {
	f := excelize.NewFile()
	defer func() { _ = f.Close() }()
	if err := f.SetSheetName(f.GetSheetName(0), pickingMainSheet); err != nil {
		return nil, fmt.Errorf("переименовать лист: %w", err)
	}
	for _, s := range []string{pickingOrdersSheet, pickingChangesSheet} {
		if _, err := f.NewSheet(s); err != nil {
			return nil, fmt.Errorf("лист %s: %w", s, err)
		}
	}
	st, err := newPickingStyles(f)
	if err != nil {
		return nil, err
	}
	for i, w := range pickingLineWidths {
		col, _ := excelize.ColumnNumberToName(i + 1)
		_ = f.SetColWidth(pickingMainSheet, col, col, w)
	}

	w := sheetWriter{f: f}
	w.styled(pickingMainSheet, st.title, "Сборка-отгрузка", "Дата накладной "+date.Format("02.01.2006"))
	w.row(pickingOrdersSheet, "Дата накладной", date.Format("02.01.2006"))
	w.next(pickingOrdersSheet)
	w.styled(pickingOrdersSheet, st.head, toAny(pickingOrderHeaders)...)
	w.styled(pickingChangesSheet, st.head, toAny(pickingChangeHeaders)...)

	for _, d := range orders {
		w.next(pickingMainSheet)
		writePickingOrderBlock(&w, st, d)

		o := d.Order
		key := []any{model.DocNumber(model.DocPrefixPicking, o.Number), o.InvoiceNumber, o.OrderNumber}
		w.row(pickingOrdersSheet, append(key,
			dateOrEmpty(o.OrderDate), o.Client, o.Direction, o.Address,
			PickingStatusTitle(o.Status), pickingFlags(o), o.AssigneeName, o.PickedByName,
			o.Lines, o.PlanQty, qtyValue(o.FactQty.String()), o.Boxes)...)
		for _, c := range d.Changes {
			w.row(pickingChangesSheet, append(append([]any{}, key...),
				c.At.In(msk).Format("02.01.2006 15:04"), pickingChangeTitle(c.Kind),
				c.GoodCode, c.GoodName, dateOrEmpty(c.BatchDate), intOrEmpty(c.OldQty), intOrEmpty(c.NewQty),
				PickingStatusTitle(c.OrderStatus))...)
		}
	}

	var buf bytes.Buffer
	if err := f.Write(&buf); err != nil {
		return nil, fmt.Errorf("запись xlsx: %w", err)
	}
	return buf.Bytes(), nil
}

// writePickingOrderBlock пишет заказ на лист «Сборка»: шапку построчно («Заказ», «Накладная»,
// «Клиент»…, каждая правка реестра — своей строкой), заголовок колонок и позиции.
func writePickingOrderBlock(w *sheetWriter, st pickingStyles, d model.PickingPortalDetail) {
	const sheet = pickingMainSheet
	o := d.Order
	status := PickingStatusTitle(o.Status)
	if flags := pickingFlags(o); flags != "" {
		status += ", " + flags
	}
	orderLine := o.OrderNumber
	if o.OrderDate != nil {
		orderLine += " от " + o.OrderDate.Format("02.01.2006")
	}
	// Исполнитель — кто держит заказ в работе, у собранного — кто и когда завершил сборку: обоих
	// сразу не бывает, поэтому одна строка.
	worker := o.AssigneeName
	if o.PickedByName != "" {
		worker = o.PickedByName
		if o.PickedAt != nil {
			worker += ", собран " + o.PickedAt.In(msk).Format("02.01.2006 15:04")
		}
	}
	w.styled(sheet, st.order, "Сборка", model.DocNumber(model.DocPrefixPicking, o.Number))
	// Исполнитель — всегда, пустая строка тоже ответ: заказ никто не взял. Коробов — числом, чтобы
	// Excel не ругался на «число как текст».
	head := []struct {
		name  string
		value any
	}{
		{"Заказ", orderLine},
		{"Накладная", o.InvoiceNumber + " от " + o.RegistryDate.Format("02.01.2006")},
		{"Клиент", o.Client},
		{"Направление", o.Direction},
		{"Адрес", o.Address},
		{"Статус", status},
		{"Исполнитель", worker},
		{"Коробов", o.Boxes},
	}
	for _, kv := range head {
		w.label(sheet, st, kv.name, kv.value)
	}
	for _, c := range d.Changes {
		w.label(sheet, st, "Правка реестра", c.At.In(msk).Format("02.01.2006 15:04")+": "+
			pickingChangeText(c))
	}

	w.styled(sheet, st.head, toAny(pickingLineHeaders)...)
	for _, l := range d.Lines {
		plan := []any{
			l.LineNo, l.GoodCode, l.GoodName, l.Uom, l.RegistryCell, batchOrAny(l.BatchDate),
			l.PlanQty, qtyValue(l.FactQty().String()),
		}
		groups := groupFacts(l.Facts)
		comment := pickingLineComment(l)
		if len(groups) == 0 {
			w.row(sheet, append(plan, "", "", "", "", comment)...)
			continue
		}
		for i, g := range groups {
			// План позиции — только в первой строке: остальные строки — продолжение факта.
			lead := make([]any, len(plan))
			if i == 0 {
				copy(lead, plan)
			}
			text := ""
			if i == 0 {
				text = comment
			}
			first := ""
			if len(g.marks) > 0 {
				first = g.marks[0]
			}
			w.row(sheet, append(lead,
				g.batch.Format("02.01.2006"), g.cell, g.box, qtyValue(trimQty(g.qty)), text, first)...)
			for _, cis := range g.marks[min(1, len(g.marks)):] {
				blank := make([]any, len(pickingLineHeaders)-1)
				w.row(sheet, append(blank, cis)...)
			}
		}
	}
}

// factGroup — факт позиции по партии, ячейке-источнику и коробу: сумма пиков и их марки.
type factGroup struct {
	batch time.Time
	cell  string
	box   string
	qty   float64
	marks []string
}

// groupFacts сводит пики позиции по партии, ячейке и коробу — в порядке первого пика.
func groupFacts(facts []model.PickingPortalFact) []*factGroup {
	var out []*factGroup
	at := map[string]*factGroup{}
	for _, f := range facts {
		key := f.BatchDate.Format(time.DateOnly) + "|" + f.CellAddress + "|" + fmt.Sprint(f.BoxSeq)
		g, ok := at[key]
		if !ok {
			g = &factGroup{batch: f.BatchDate, cell: f.CellAddress, box: fmt.Sprintf("Короб %d", f.BoxSeq)}
			at[key] = g
			out = append(out, g)
		}
		q, _ := f.Qty.Float64()
		g.qty += q
		g.marks = append(g.marks, f.Marks...)
	}
	return out
}

// pickingLineComment — что по позиции надо знать офису, через «; »: нет в номенклатуре, ячейки
// реестра нет в WMS, убрана реестром, «не хватает», сколько ещё «в сборке» (не в коробе),
// замена партии реестра.
func pickingLineComment(l model.PickingPortalLine) string {
	var notes []string
	if !l.Known {
		notes = append(notes, "нет в номенклатуре")
	}
	if l.RegistryCell != "" && l.CellAddress == "" {
		notes = append(notes, "ячейки реестра нет в WMS")
	}
	if l.Removed {
		notes = append(notes, "убрана реестром")
	}
	if l.Shortage {
		notes = append(notes, "не хватает")
	}
	inPicking, substituted := 0.0, false
	for _, f := range l.Facts {
		if f.State != "moved" {
			q, _ := f.Qty.Float64()
			inPicking += q
		}
		if l.BatchDate != nil && !f.BatchDate.Equal(*l.BatchDate) {
			substituted = true
		}
	}
	if inPicking > 0 {
		notes = append(notes, "в сборке "+trimQty(inPicking))
	}
	if substituted {
		notes = append(notes, "замена партии")
	}
	return strings.Join(notes, "; ")
}

// pickingChangeText — правка реестра для человека: «Изменено количество: 2 → 3».
func pickingChangeText(c model.PickingPortalChange) string {
	good := strings.TrimSpace(c.GoodCode + " " + c.GoodName)
	switch c.Kind {
	case model.PickingChangeLineAdded:
		return fmt.Sprintf("добавлено %s, количество %s", good, intText(c.NewQty))
	case model.PickingChangeLineRemoved:
		return fmt.Sprintf("убрано %s, было %s", good, intText(c.OldQty))
	case model.PickingChangeQtyChanged:
		return fmt.Sprintf("изменено %s, количество %s → %s", good, intText(c.OldQty), intText(c.NewQty))
	default:
		return pickingChangeTitle(c.Kind)
	}
}

func intText(v *int) string {
	if v == nil {
		return "0"
	}
	return fmt.Sprint(*v)
}

// batchOrAny — партия реестра; без партии — «любая» (FEFO), как в окне деталей.
func batchOrAny(t *time.Time) string {
	if t == nil {
		return "любая"
	}
	return t.Format("02.01.2006")
}

// pickingStyles — оформление листа «Сборка»: заголовок файла, строка номера сборки, подписи
// шапки заказа и их значения, заголовок колонок.
type pickingStyles struct {
	title, order, label, value, head int
}

func newPickingStyles(f *excelize.File) (pickingStyles, error) {
	var st pickingStyles
	var err error
	bold := &excelize.Font{Bold: true}
	if st.title, err = f.NewStyle(&excelize.Style{Font: &excelize.Font{Bold: true, Size: 13}}); err != nil {
		return st, fmt.Errorf("стиль: %w", err)
	}
	if st.order, err = f.NewStyle(&excelize.Style{
		Font: &excelize.Font{Bold: true, Size: 12},
		Fill: excelize.Fill{Type: "pattern", Pattern: 1, Color: []string{"DDEBF7"}},
	}); err != nil {
		return st, fmt.Errorf("стиль: %w", err)
	}
	if st.label, err = f.NewStyle(&excelize.Style{Font: bold}); err != nil {
		return st, fmt.Errorf("стиль: %w", err)
	}
	// Значение шапки — по левому краю, и число тоже (иначе «Коробов» уезжает вправо).
	if st.value, err = f.NewStyle(&excelize.Style{Alignment: &excelize.Alignment{Horizontal: "left"}}); err != nil {
		return st, fmt.Errorf("стиль: %w", err)
	}
	if st.head, err = f.NewStyle(&excelize.Style{
		Font:   bold,
		Fill:   excelize.Fill{Type: "pattern", Pattern: 1, Color: []string{"F2F2F2"}},
		Border: []excelize.Border{{Type: "bottom", Color: "999999", Style: 1}},
	}); err != nil {
		return st, fmt.Errorf("стиль: %w", err)
	}
	return st, nil
}

// PickingXLSXName — имя файла выгрузки: дата накладной в имени, по ней файлы и различают.
func PickingXLSXName(warehouseCode string, date time.Time) string {
	return fmt.Sprintf("sborka-%s-%s.xlsx", warehouseCode, date.Format("20060102"))
}

// trimQty — количество без лишних нулей: 3, 2.5.
func trimQty(v float64) string {
	return strings.TrimRight(strings.TrimRight(fmt.Sprintf("%.3f", v), "0"), ".")
}

func dateOrEmpty(t *time.Time) string {
	if t == nil {
		return ""
	}
	return t.Format("02.01.2006")
}

func intOrEmpty(v *int) any {
	if v == nil {
		return ""
	}
	return *v
}

func toAny(ss []string) []any {
	out := make([]any, len(ss))
	for i, s := range ss {
		out[i] = s
	}
	return out
}

// sheetWriter пишет строки листов подряд: помнит следующую строку каждого листа.
type sheetWriter struct {
	f    *excelize.File
	rows map[string]int
}

// row пишет значения в следующую строку листа.
func (w *sheetWriter) row(sheet string, values ...any) {
	if w.rows == nil {
		w.rows = map[string]int{}
	}
	w.rows[sheet]++
	for i, v := range values {
		_ = w.f.SetCellValue(sheet, cellName(i+1, w.rows[sheet]), v)
	}
}

// label пишет строку «подпись — значение» шапки заказа: подпись — в A:B (узкая «№» её не
// вмещает) жирным, значение — в C и дальше на всю ширину позиций, по левому краю.
func (w *sheetWriter) label(sheet string, st pickingStyles, name string, value any) {
	r := w.pair(sheet, name, value)
	_ = w.f.SetCellStyle(sheet, cellName(1, r), cellName(2, r), st.label)
	_ = w.f.SetCellStyle(sheet, cellName(3, r), cellName(len(pickingLineHeaders), r), st.value)
}

// styled пишет значения в следующую строку листа и оформляет её целиком. Пара значений
// (заголовок, номер сборки) — как строка шапки, но заливка идёт через весь блок.
func (w *sheetWriter) styled(sheet string, style int, values ...any) {
	if len(values) == 2 && sheet == pickingMainSheet {
		r := w.pair(sheet, values[0], values[1])
		_ = w.f.SetCellStyle(sheet, cellName(1, r), cellName(len(pickingLineHeaders), r), style)
		return
	}
	w.row(sheet, values...)
	r := w.rows[sheet]
	_ = w.f.SetCellStyle(sheet, cellName(1, r), cellName(len(values), r), style)
}

// pair — строка шапки листа «Сборка»: подпись в объединённых A:B, значение — C до последней
// колонки позиций. Возвращает номер строки.
func (w *sheetWriter) pair(sheet string, name, value any) int {
	if w.rows == nil {
		w.rows = map[string]int{}
	}
	w.rows[sheet]++
	r := w.rows[sheet]
	_ = w.f.SetCellValue(sheet, cellName(1, r), name)
	_ = w.f.SetCellValue(sheet, cellName(3, r), value)
	_ = w.f.MergeCell(sheet, cellName(1, r), cellName(2, r))
	_ = w.f.MergeCell(sheet, cellName(3, r), cellName(len(pickingLineHeaders), r))
	return r
}

// next пропускает строку листа.
func (w *sheetWriter) next(sheet string) {
	if w.rows == nil {
		w.rows = map[string]int{}
	}
	w.rows[sheet]++
}
