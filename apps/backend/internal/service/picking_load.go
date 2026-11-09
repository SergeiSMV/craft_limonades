package service

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"time"

	"craftwms/internal/importer"
	"craftwms/internal/model"
)

// ErrRegistryFile — файл реестра не принят целиком (нет листа или колонки, нет принятых строк,
// несколько дат): ошибка ввода оператора, а не сбой.
var ErrRegistryFile = errors.New("реестр не принят")

// pickingLoadRepo — узкий интерфейс хранилища сборки для загрузки реестра (P8-02).
type pickingLoadRepo interface {
	ExistingOrders(ctx context.Context, warehouseID string, date time.Time) ([]model.PickingExistingOrder, error)
	CellAddresses(ctx context.Context, warehouseID string) (map[string]string, error)
	Stock(ctx context.Context, warehouseID string, goodIDs []string) ([]model.PickingStock, error)
	Load(ctx context.Context, in model.PickingLoadInput,
		build func([]model.PickingExistingOrder) ([]model.PickingOrderPlan, error)) (string, []model.PickingOrderPlan, error)
}

// pickingWarehouses — физический склад по коду: реестр грузится на склад пилота.
type pickingWarehouses interface {
	IDByCode(ctx context.Context, code string) (string, error)
}

// PickingLoadService — загрузка «Реестра» 1С в портале (P8-02): предпросмотр и подтверждение.
//
// Предпросмотр ничего не пишет: разбирает файл, сверяет с заказами той же даты и подсвечивает
// нераспознанные коды, ячейки, которых нет в WMS, и нехватку остатка. Загрузка повторяет ту же
// сверку под блокировкой даты и пишет её одной транзакцией — задания появляются только после
// явного подтверждения оператора.
type PickingLoadService struct {
	parser     *PickingRegistryService
	repo       pickingLoadRepo
	warehouses pickingWarehouses
}

// NewPickingLoadService собирает сервис загрузки реестра.
func NewPickingLoadService(parser *PickingRegistryService, repo pickingLoadRepo, warehouses pickingWarehouses) *PickingLoadService {
	return &PickingLoadService{parser: parser, repo: repo, warehouses: warehouses}
}

// RegistryPreview — предпросмотр (и итог) загрузки реестра.
type RegistryPreview struct {
	LoadID       string              `json:"load_id,omitempty"` // только у записанной загрузки
	Date         string              `json:"date"`              // дата накладных, 2006-01-02
	Counts       RegistryCounts      `json:"counts"`
	Orders       []PreviewOrder      `json:"orders"`
	UnknownCodes []string            `json:"unknown_codes"`
	Errors       []importer.RowError `json:"errors"`
}

// RegistryCounts — сколько заказов какой вид правки получили.
type RegistryCounts struct {
	New       int `json:"new"`
	Unchanged int `json:"unchanged"`
	Changed   int `json:"changed"`
	Deleted   int `json:"deleted"`
	Restored  int `json:"restored"`
}

// PreviewOrder — заказ в предпросмотре. Status — статус WMS до загрузки; Shipped — правка не
// двигает товар, только помечает заказ; Reopen — собранный заказ уйдёт на дособор.
type PreviewOrder struct {
	Kind          string          `json:"kind"`
	Number        *int64          `json:"number,omitempty"`
	Status        string          `json:"status"`
	InvoiceNumber string          `json:"invoice_number"`
	OrderNumber   string          `json:"order_number"`
	Client        string          `json:"client"`
	Address       string          `json:"address"`
	Direction     string          `json:"direction"`
	HasUnknown    bool            `json:"has_unknown"`
	HasShortage   bool            `json:"has_shortage"`
	Shipped       bool            `json:"shipped"`
	Reopen        bool            `json:"reopen"`
	Lines         []PreviewLine   `json:"lines"`
	Changes       []PreviewChange `json:"changes"`
}

// PreviewLine — строка плана. Available — остаток для сборки по товару и партии (без партии — по
// товару целиком); Shortage — остатка не хватает на все собирающиеся заказы файла с этой позицией.
type PreviewLine struct {
	GoodCode  string   `json:"good_code"`
	GoodName  string   `json:"good_name"`
	Known     bool     `json:"known"`
	BatchDate *string  `json:"batch_date"`
	Qty       int      `json:"qty"`
	Cell      string   `json:"cell"`
	CellFound bool     `json:"cell_found"`
	Available *float64 `json:"available,omitempty"`
	Shortage  bool     `json:"shortage"`
}

// PreviewChange — правка заказа против прошлой загрузки.
type PreviewChange struct {
	Kind      string  `json:"kind"`
	GoodCode  string  `json:"good_code,omitempty"`
	GoodName  string  `json:"good_name,omitempty"`
	BatchDate *string `json:"batch_date,omitempty"`
	OldQty    *int    `json:"old_qty,omitempty"`
	NewQty    *int    `json:"new_qty,omitempty"`
}

// Preview разбирает файл и показывает, что сделает загрузка, ничего не записывая.
func (s *PickingLoadService) Preview(ctx context.Context, warehouseCode string, r io.Reader) (*RegistryPreview, error) {
	parsed, warehouseID, cells, err := s.prepare(ctx, warehouseCode, r)
	if err != nil {
		return nil, err
	}
	existing, err := s.repo.ExistingOrders(ctx, warehouseID, parsed.Date)
	if err != nil {
		return nil, err
	}
	return s.preview(ctx, warehouseID, parsed, planRegistry(parsed, cells, existing))
}

// Load записывает реестр: заказы, строки плана, правки и загрузку. userID — кто загрузил.
func (s *PickingLoadService) Load(ctx context.Context, warehouseCode, fileName, userID string, r io.Reader) (*RegistryPreview, error) {
	parsed, warehouseID, cells, err := s.prepare(ctx, warehouseCode, r)
	if err != nil {
		return nil, err
	}
	loadID, plans, err := s.repo.Load(ctx, model.PickingLoadInput{
		WarehouseID: warehouseID, RegistryDate: parsed.Date, FileName: fileName, UploadedBy: userID,
	}, func(existing []model.PickingExistingOrder) ([]model.PickingOrderPlan, error) {
		return planRegistry(parsed, cells, existing), nil
	})
	if err != nil {
		return nil, err
	}
	out, err := s.preview(ctx, warehouseID, parsed, plans)
	if err != nil {
		return nil, err
	}
	out.LoadID = loadID
	return out, nil
}

// prepare — разбор файла, склад и ячейки WMS по ключу адреса (model.CellAddressKey).
func (s *PickingLoadService) prepare(ctx context.Context, warehouseCode string, r io.Reader) (*RegistryParsed, string, map[string]string, error) {
	// Файл читается целиком: excelize всё равно держит книгу в памяти, а потолок размера задаёт
	// хендлер.
	raw, err := io.ReadAll(r)
	if err != nil {
		return nil, "", nil, fmt.Errorf("чтение файла: %w", err)
	}
	parsed, err := s.parser.Parse(ctx, bytes.NewReader(raw))
	if err != nil {
		return nil, "", nil, err
	}
	warehouseID, err := s.warehouses.IDByCode(ctx, warehouseCode)
	if err != nil {
		return nil, "", nil, err
	}
	byAddress, err := s.repo.CellAddresses(ctx, warehouseID)
	if err != nil {
		return nil, "", nil, err
	}
	cells := make(map[string]string, len(byAddress))
	for address, id := range byAddress {
		key := model.CellAddressKey(address)
		if _, dup := cells[key]; !dup {
			cells[key] = id
		}
	}
	return parsed, warehouseID, cells, nil
}

// lineKey — тройка строки без заказа: код товара и партия (пусто — без партии).
func lineKey(code string, batch *time.Time) string {
	if batch == nil {
		return code + "|"
	}
	return code + "|" + batch.Format(time.DateOnly)
}

// foldLines сводит строки файла заказа в строки плана: тройка, повторённая в файле, — одна строка
// с суммой количества и первой ячейкой (docs/picking.md, «Загрузка и повторы»).
func foldLines(lines []RegistryLine, cells map[string]string) []model.PickingPlanLine {
	var out []model.PickingPlanLine
	idx := map[string]int{}
	for _, l := range lines {
		k := lineKey(l.GoodCode, l.Batch)
		if i, ok := idx[k]; ok {
			out[i].Qty += l.Qty
			continue
		}
		pl := model.PickingPlanLine{
			GoodCode: l.GoodCode, GoodName: l.GoodName, BatchDate: l.Batch, Qty: l.Qty, RegistryCell: l.CellAddress,
		}
		if l.Good != nil {
			id := l.Good.ID
			pl.GoodID = &id
		}
		if l.CellAddress != "" {
			if id, ok := cells[model.CellAddressKey(l.CellAddress)]; ok {
				pl.CellID = &id
			}
		}
		idx[k] = len(out)
		out = append(out, pl)
	}
	return out
}

// planRegistry сверяет файл с заказами той же даты и решает, что делать с каждым заказом.
//
// Что: план по заказам файла (новый, без изменений, изменён, вернулся) и по пропавшим (удалён).
// Зачем: одна и та же сверка нужна предпросмотру и загрузке — загрузка повторяет её под
// блокировкой даты по свежему состоянию. Как: строки сравниваются по тройке «код + партия»;
// убранная раньше строка, вернувшаяся в реестр, — снова добавленная. Правила по статусу —
// docs/picking.md: отгруженный заказ замораживается (только правки и пометка), собранному с
// добавленным товаром — дособор.
func planRegistry(parsed *RegistryParsed, cells map[string]string, existing []model.PickingExistingOrder) []model.PickingOrderPlan {
	byNumber := make(map[string]*model.PickingExistingOrder, len(existing))
	for i := range existing {
		byNumber[existing[i].OrderNumber] = &existing[i]
	}
	inFile := map[string]bool{}
	plans := make([]model.PickingOrderPlan, 0, len(parsed.Orders))

	for _, o := range parsed.Orders {
		inFile[o.OrderNumber] = true
		p := model.PickingOrderPlan{
			Kind:   model.PickingOrderNew,
			Status: model.PickingStatusNew,
			Header: &model.PickingOrderHeader{
				InvoiceNumber: o.InvoiceNumber, OrderNumber: o.OrderNumber, OrderDate: o.OrderDate,
				Direction: o.Direction, Client: o.Client, Address: o.Address, HasUnknown: o.HasUnknown,
			},
			Lines: foldLines(o.Lines, cells),
		}
		ex, ok := byNumber[o.OrderNumber]
		if !ok {
			plans = append(plans, p)
			continue
		}
		p.ExistingID, p.Status, p.PickedBy = ex.ID, ex.Status, ex.PickedBy
		p.Frozen = ex.Status == model.PickingStatusShipped

		old := make(map[string]model.PickingExistingLine, len(ex.Lines))
		for _, l := range ex.Lines {
			old[lineKey(l.GoodCode, l.BatchDate)] = l
		}
		seen := map[string]bool{}
		added := false
		for i := range p.Lines {
			l := &p.Lines[i]
			k := lineKey(l.GoodCode, l.BatchDate)
			seen[k] = true
			el, had := old[k]
			if had {
				l.ExistingID = el.ID
			}
			newQty := l.Qty
			switch {
			case !had || el.Removed:
				added = true
				p.Changes = append(p.Changes, model.PickingChange{
					Kind: model.PickingChangeLineAdded, GoodCode: l.GoodCode, GoodName: l.GoodName,
					BatchDate: l.BatchDate, NewQty: &newQty,
				})
			case el.PlanQty != l.Qty:
				oldQty := el.PlanQty
				if l.Qty > oldQty {
					added = true
				}
				p.Changes = append(p.Changes, model.PickingChange{
					Kind: model.PickingChangeQtyChanged, GoodCode: l.GoodCode, GoodName: l.GoodName,
					BatchDate: l.BatchDate, OldQty: &oldQty, NewQty: &newQty,
				})
			}
		}
		for _, el := range ex.Lines {
			if el.Removed || seen[lineKey(el.GoodCode, el.BatchDate)] {
				continue
			}
			oldQty := el.PlanQty
			p.RemovedLineIDs = append(p.RemovedLineIDs, el.ID)
			p.Changes = append(p.Changes, model.PickingChange{
				Kind: model.PickingChangeLineRemoved, GoodCode: el.GoodCode, GoodName: el.GoodName,
				BatchDate: el.BatchDate, OldQty: &oldQty,
			})
		}

		switch {
		case ex.Deleted:
			p.Kind = model.PickingOrderRestored
			p.Changes = append([]model.PickingChange{{Kind: model.PickingChangeOrderRestored}}, p.Changes...)
		case len(p.Changes) > 0:
			p.Kind = model.PickingOrderChanged
		default:
			p.Kind = model.PickingOrderUnchanged
		}
		p.Reopen = added && ex.Status == model.PickingStatusPicked
		plans = append(plans, p)
	}

	for i := range existing {
		ex := &existing[i]
		if ex.Deleted || inFile[ex.OrderNumber] {
			continue
		}
		plans = append(plans, model.PickingOrderPlan{
			Kind: model.PickingOrderDeleted, ExistingID: ex.ID, Status: ex.Status,
			Frozen:  ex.Status == model.PickingStatusShipped,
			Changes: []model.PickingChange{{Kind: model.PickingChangeOrderDeleted}},
		})
	}
	return plans
}

// preview собирает ответ из плана: строки заказов из файла, у удалённого — его прошлые строки, и
// подсветку нехватки.
func (s *PickingLoadService) preview(ctx context.Context, warehouseID string, parsed *RegistryParsed, plans []model.PickingOrderPlan) (*RegistryPreview, error) {
	existing, err := s.repo.ExistingOrders(ctx, warehouseID, parsed.Date)
	if err != nil {
		return nil, err
	}
	byID := make(map[string]model.PickingExistingOrder, len(existing))
	for _, o := range existing {
		byID[o.ID] = o
	}

	out := &RegistryPreview{
		Date:         parsed.Date.Format(time.DateOnly),
		UnknownCodes: parsed.UnknownCodes,
		Errors:       parsed.Errors,
		Orders:       make([]PreviewOrder, 0, len(plans)),
	}
	if out.UnknownCodes == nil {
		out.UnknownCodes = []string{}
	}
	if out.Errors == nil {
		out.Errors = []importer.RowError{}
	}

	goodIDs := map[string]bool{}
	for _, p := range plans {
		for _, l := range p.Lines {
			if l.GoodID != nil {
				goodIDs[*l.GoodID] = true
			}
		}
	}
	ids := make([]string, 0, len(goodIDs))
	for id := range goodIDs {
		ids = append(ids, id)
	}
	stock, err := s.repo.Stock(ctx, warehouseID, ids)
	if err != nil {
		return nil, err
	}
	short := newShortage(stock)
	for _, p := range plans {
		if collectsDemand(p) {
			for _, l := range p.Lines {
				short.add(l)
			}
		}
	}

	for _, p := range plans {
		po := PreviewOrder{
			Kind: p.Kind, Status: p.Status, Shipped: p.Frozen, Reopen: p.Reopen,
			Lines: []PreviewLine{}, Changes: make([]PreviewChange, 0, len(p.Changes)),
		}
		if ex, ok := byID[p.ExistingID]; ok {
			n := ex.Number
			po.Number = &n
			if p.Kind == model.PickingOrderDeleted {
				po.OrderNumber = ex.OrderNumber
			}
		}
		if h := p.Header; h != nil {
			po.InvoiceNumber, po.OrderNumber, po.Client = h.InvoiceNumber, h.OrderNumber, h.Client
			po.Address, po.Direction, po.HasUnknown = h.Address, h.Direction, h.HasUnknown
		}
		for _, l := range p.Lines {
			pl := PreviewLine{
				GoodCode: l.GoodCode, GoodName: l.GoodName, Known: l.GoodID != nil, BatchDate: dateStr(l.BatchDate),
				Qty: l.Qty, Cell: l.RegistryCell, CellFound: l.CellID != nil,
			}
			if l.GoodID != nil && collectsDemand(p) {
				avail := short.available(l)
				pl.Available = &avail
				pl.Shortage = short.short(l)
				po.HasShortage = po.HasShortage || pl.Shortage
			}
			po.Lines = append(po.Lines, pl)
		}
		for _, c := range p.Changes {
			po.Changes = append(po.Changes, PreviewChange{
				Kind: c.Kind, GoodCode: c.GoodCode, GoodName: c.GoodName, BatchDate: dateStr(c.BatchDate),
				OldQty: c.OldQty, NewQty: c.NewQty,
			})
		}
		switch p.Kind {
		case model.PickingOrderNew:
			out.Counts.New++
		case model.PickingOrderUnchanged:
			out.Counts.Unchanged++
		case model.PickingOrderChanged:
			out.Counts.Changed++
		case model.PickingOrderDeleted:
			out.Counts.Deleted++
		case model.PickingOrderRestored:
			out.Counts.Restored++
		}
		out.Orders = append(out.Orders, po)
	}
	return out, nil
}

// collectsDemand — заказ ещё будут собирать из ячеек: новый или в работе, не удалён. Собранный
// уже лежит в `ОТГРУЗКЕ`, отгруженный уехал — их план с остатком ячеек не сравнивается.
func collectsDemand(p model.PickingOrderPlan) bool {
	if p.Kind == model.PickingOrderDeleted {
		return false
	}
	return p.Status == model.PickingStatusNew || p.Status == model.PickingStatusInProgress
}

// shortage — нехватка остатка на файл целиком: план всех собирающихся заказов по товару и
// партии против остатка для сборки. Строка без партии берёт любую партию товара.
type shortage struct {
	stock       map[string]float64 // товар|партия → остаток
	total       map[string]float64 // товар → остаток всех партий
	demand      map[string]float64 // товар|партия → план
	demandTotal map[string]float64 // товар → план всех строк, с партией и без
}

func newShortage(stock []model.PickingStock) *shortage {
	s := &shortage{
		stock: map[string]float64{}, total: map[string]float64{},
		demand: map[string]float64{}, demandTotal: map[string]float64{},
	}
	for _, st := range stock {
		b := st.BatchDate
		s.stock[lineKey(st.GoodID, &b)] += st.Qty
		s.total[st.GoodID] += st.Qty
	}
	return s
}

func (s *shortage) add(l model.PickingPlanLine) {
	if l.GoodID == nil {
		return
	}
	s.demandTotal[*l.GoodID] += float64(l.Qty)
	if l.BatchDate != nil {
		s.demand[lineKey(*l.GoodID, l.BatchDate)] += float64(l.Qty)
	}
}

func (s *shortage) available(l model.PickingPlanLine) float64 {
	if l.BatchDate != nil {
		return s.stock[lineKey(*l.GoodID, l.BatchDate)]
	}
	return s.total[*l.GoodID]
}

func (s *shortage) short(l model.PickingPlanLine) bool {
	if l.BatchDate != nil {
		k := lineKey(*l.GoodID, l.BatchDate)
		return s.demand[k] > s.stock[k]
	}
	return s.demandTotal[*l.GoodID] > s.total[*l.GoodID]
}

func dateStr(t *time.Time) *string {
	if t == nil {
		return nil
	}
	v := t.Format(time.DateOnly)
	return &v
}
