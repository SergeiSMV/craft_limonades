package repository

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/shopspring/decimal"

	"craftwms/internal/model"
)

// Ошибки документа приёмки (P4-02).
var (
	// ErrReceiptNotFound - нет документа с таким id.
	ErrReceiptNotFound = errors.New("receipt not found")
	// ErrReceiptPosted - документ уже оприходован: строки не меняются, повтор запрещён.
	ErrReceiptPosted = errors.New("receipt already posted")
	// ErrEmptyReceipt - оприходовать нечего: в документе нет строк.
	ErrEmptyReceipt = errors.New("receipt has no lines")
	// ErrLoadUnitCellConflict - строки одной ГЕ указывают разные ячейки.
	ErrLoadUnitCellConflict = errors.New("load unit lines point to different cells")
)

// ReceiptRepository - документ приёмки: набор строк и оприходование.
// Оприходование владеет транзакцией (приём из StockRepository.Transfer и финала сессии).
type ReceiptRepository struct {
	pool *pgxpool.Pool
}

// NewReceiptRepository создаёт репозиторий приёмки.
func NewReceiptRepository(pool *pgxpool.Pool) *ReceiptRepository {
	return &ReceiptRepository{pool: pool}
}

// Create открывает документ с идентификатором, выданным устройством, идемпотентно:
// повтор с тем же id возвращает существующий документ, а не заводит второй.
//
// Зачем id с устройства: приёмка начинается на ТСД, в том числе без сети, и серверный
// идентификатор взять неоткуда - кладовщик не смог бы продолжить начатый документ.
// Тот же приём, что у сессии ввода остатков (P-FS-04).
func (r *ReceiptRepository) Create(ctx context.Context, id, warehouseID, supplierID, createdBy string, doc model.SupplierDoc) error {
	return createReceipt(ctx, r.pool, id, warehouseID, supplierID, createdBy, doc)
}

// createReceipt - низкоуровневое открытие документа на Querier: им пользуется и прямая ручка,
// и применение приёмки из очереди устройства (P4-09), где документ открывается в одной
// транзакции со своими строками и оприходованием.
//
// [doc] - накладная поставщика (ADHOC-23); проверена сервисом, база держит тот же CHECK.
func createReceipt(ctx context.Context, q Querier, id, warehouseID, supplierID, createdBy string, doc model.SupplierDoc) error {
	var supplier any
	if supplierID != "" {
		supplier = supplierID
	}
	_, err := q.Exec(ctx, `
		INSERT INTO receipts (id, warehouse_id, supplier_id, created_by, doc_number, doc_date)
		VALUES ($1::uuid, $2::uuid, $3::uuid, $4::uuid, $5, $6::date)
		ON CONFLICT (id) DO NOTHING`, id, warehouseID, supplier, createdBy, doc.Number, doc.Date)
	if err != nil {
		return fmt.Errorf("создать приёмку: %w", err)
	}
	return nil
}

// AddLine добавляет строку в документ-черновик. Партия задаётся датой выпуска и создаётся
// при необходимости (идемпотентно, P-FS-02).
//
// Повторный скан той же комбинации (товар · партия · ячейка · ГЕ) УВЕЛИЧИВАЕТ количество,
// а не плодит строки: кладовщик сканирует одну и ту же позицию несколько раз подряд, и каждая
// такая строка в документе была бы шумом.
func (r *ReceiptRepository) AddLine(ctx context.Context, receiptID string, in model.ReceiptLineInput) error {
	return WithinTx(ctx, r.pool, func(q Querier) error {
		if err := guardReceiptDraft(ctx, q, receiptID); err != nil {
			return err
		}
		return insertReceiptLine(ctx, q, receiptID, in)
	})
}

// receiptMarkCIS - КИ марок строки приёмки: строка хранит сами марки, а расхождения с ЧЗ
// уже ушли проблемами склада.
func receiptMarkCIS(marks []model.ReceiptMark) []string {
	out := make([]string, len(marks)) // не nil: колонка NOT NULL
	for i, m := range marks {
		out[i] = m.CIS
	}
	return out
}

// insertReceiptLine - вставка строки в документ на Querier, без проверки статуса: её делает
// вызывающий один раз на документ, а не на каждую строку.
func insertReceiptLine(ctx context.Context, q Querier, receiptID string, in model.ReceiptLineInput) error {
	batchID, err := getOrCreateBatch(ctx, q, in.GoodID, in.ProductionDate)
	if err != nil {
		return err
	}
	var lu any
	if in.LoadUnitID != "" {
		// Короб проверяем ДО вставки строки: без этого незнакомый ярлык упирался бы
		// в нарушение внешнего ключа, и кладовщик получал бы сбой БД вместо внятного
		// «такой ГЕ нет» - а это его рабочая ситуация, не авария.
		if err := guardLoadUnitExists(ctx, q, in.LoadUnitID); err != nil {
			return err
		}
		lu = in.LoadUnitID
	}
	_, err = q.Exec(ctx, `
		INSERT INTO receipt_lines (receipt_id, good_id, batch_id, cell_id, load_unit_id, qty, marks)
		VALUES ($1::uuid, $2::uuid, $3::uuid, $4::uuid, $5::uuid, $6::numeric, $7::text[])
		ON CONFLICT (receipt_id, good_id, batch_id, cell_id, load_unit_id)
		DO UPDATE SET qty = receipt_lines.qty + EXCLUDED.qty,
		              marks = receipt_lines.marks || EXCLUDED.marks`,
		receiptID, in.GoodID, batchID, in.CellID, lu, in.Qty.String(), receiptMarkCIS(in.Marks))
	if err != nil {
		return fmt.Errorf("добавить строку приёмки: %w", err)
	}
	return nil
}

// Post оприходует документ: строки поднимают остаток, состав ГЕ пополняется, документ
// переходит в posted. Всё в одной транзакции.
//
// Оприходование ДОБАВЛЯЕТ к остатку, в отличие от ввода остатков, который его фиксирует.
// Поэтому повтор здесь опасен - он удвоил бы приход, - и закрыт статусом: второй вызов
// упирается в guard и получает ErrReceiptPosted.
func (r *ReceiptRepository) Post(ctx context.Context, receiptID string) (int, error) {
	var posted int
	err := WithinTx(ctx, r.pool, func(q Querier) error {
		var err error
		posted, err = postReceipt(ctx, q, receiptID)
		return err
	})
	if err != nil {
		return 0, err
	}
	return posted, nil
}

// postReceipt - низкоуровневое оприходование на Querier, чтобы применение из очереди
// устройства шло в одной транзакции с пометкой операции (P2-05).
func postReceipt(ctx context.Context, q Querier, receiptID string) (int, error) {
	if err := guardReceiptDraft(ctx, q, receiptID); err != nil {
		return 0, err
	}
	lines, err := listReceiptLines(ctx, q, receiptID)
	if err != nil {
		return 0, err
	}
	if len(lines) == 0 {
		return 0, ErrEmptyReceipt
	}

	// Приёмка приходует в склад по умолчанию: выбор учётной принадлежности сделан для
	// размещения (P5), а не для приёмки - решение заказчика (ADR-0016).
	iwh, err := defaultInternalWarehouse(ctx, q)
	if err != nil {
		return 0, err
	}

	// Короб не может лежать в двух местах: если строки одной ГЕ указывают разные ячейки,
	// документ противоречив, и молча выбрать одну из них значило бы соврать про место хранения.
	luCell := map[string]string{}
	for _, ln := range lines {
		if ln.LoadUnitID == nil {
			continue
		}
		if prev, ok := luCell[*ln.LoadUnitID]; ok && prev != ln.CellID {
			return 0, ErrLoadUnitCellConflict
		}
		luCell[*ln.LoadUnitID] = ln.CellID
	}

	for _, ln := range lines {
		key := model.StockKey{
			CellID: ln.CellID, GoodID: ln.GoodID, BatchID: ln.BatchID, InternalWarehouseID: iwh,
		}
		if err := addStock(ctx, q, key, ln.Qty); err != nil {
			return 0, err
		}
		if ln.LoadUnitID != nil {
			if err := addLoadUnitContent(ctx, q, *ln.LoadUnitID, ln.GoodID, ln.BatchID, ln.Qty.String()); err != nil {
				return 0, err
			}
		}
	}

	// ГЕ уезжает в ту ячейку, куда её приняли, и считается размещённой: приёмка кладёт короб
	// на место сразу (по умолчанию - дефолтная ячейка). Перенос идёт через общую функцию
	// размещения - она же пишет первую строку журнала (P5-01).
	var createdBy string
	if err := q.QueryRow(ctx, `SELECT created_by::text FROM receipts WHERE id = $1::uuid`, receiptID).
		Scan(&createdBy); err != nil {
		return 0, fmt.Errorf("прочитать автора приёмки: %w", err)
	}
	for luID, cellID := range luCell {
		if err := placeLoadUnit(ctx, q, model.PlaceLoadUnitInput{
			LoadUnitID: luID,
			CellID:     cellID,
			Source:     model.PlacementReceipt,
			UserID:     createdBy,
			ReceiptID:  &receiptID,
		}); err != nil {
			return 0, err
		}
	}

	// Что приёмка оставила в ячейке приёмки, становится заданием на размещение (P5-02-1) -
	// в той же транзакции: оприходованная приёмка без задания потеряла бы свой хвост.
	if err := createPutawayTaskForReceipt(ctx, q, receiptID); err != nil {
		return 0, err
	}

	if _, err := q.Exec(ctx, `
		UPDATE receipts SET status = 'posted', posted_at = now()
		WHERE id = $1::uuid`, receiptID); err != nil {
		return 0, fmt.Errorf("оприходовать приёмку: %w", err)
	}

	// Документ «Поступление» - в ЭТОЙ ЖЕ транзакции (P4-10): оприходованная приёмка без
	// документа невозможна, как и документ по неоприходованной. Путь один и для прямой ручки,
	// и для операции очереди - обе проводят приёмку здесь.
	if err := saveReceiptDocument(ctx, q, receiptID); err != nil {
		return 0, err
	}
	return len(lines), nil
}

// addLoadUnitContent пополняет состав ГЕ по грани (ГЕ · товар · партия).
func addLoadUnitContent(ctx context.Context, q Querier, luID, goodID, batchID, qty string) error {
	_, err := q.Exec(ctx, `
		INSERT INTO lu_content (load_unit_id, good_id, batch_id, qty)
		VALUES ($1::uuid, $2::uuid, $3::uuid, $4::numeric)
		ON CONFLICT (load_unit_id, good_id, batch_id)
		DO UPDATE SET qty = lu_content.qty + EXCLUDED.qty`, luID, goodID, batchID, qty)
	if err != nil {
		return fmt.Errorf("пополнить состав ГЕ: %w", err)
	}
	return nil
}

// guardLoadUnitExists проверяет, что ГЕ заведена.
func guardLoadUnitExists(ctx context.Context, q Querier, luID string) error {
	var exists bool
	err := q.QueryRow(ctx, `SELECT true FROM load_units WHERE id = $1::uuid`, luID).Scan(&exists)
	if errors.Is(err, pgx.ErrNoRows) {
		return ErrLoadUnitNotFound
	}
	if err != nil {
		return fmt.Errorf("проверить ГЕ: %w", err)
	}
	return nil
}

// guardReceiptDraft проверяет, что документ существует и ещё в работе.
func guardReceiptDraft(ctx context.Context, q Querier, receiptID string) error {
	var status string
	err := q.QueryRow(ctx, `SELECT status FROM receipts WHERE id = $1::uuid`, receiptID).Scan(&status)
	if errors.Is(err, pgx.ErrNoRows) {
		return ErrReceiptNotFound
	}
	if err != nil {
		return fmt.Errorf("статус приёмки: %w", err)
	}
	if status != model.ReceiptDraft {
		return ErrReceiptPosted
	}
	return nil
}

// listReceiptLines читает строки документа для оприходования.
func listReceiptLines(ctx context.Context, q Querier, receiptID string) ([]model.ReceiptLine, error) {
	rows, err := q.Query(ctx, `
		SELECT id::text, good_id::text, batch_id::text, cell_id::text, load_unit_id::text, qty::text, marks
		FROM receipt_lines WHERE receipt_id = $1::uuid
		ORDER BY created_at, id`, receiptID)
	if err != nil {
		return nil, fmt.Errorf("строки приёмки: %w", err)
	}
	defer rows.Close()

	out := make([]model.ReceiptLine, 0)
	for rows.Next() {
		var ln model.ReceiptLine
		var qty string
		if err := rows.Scan(&ln.ID, &ln.GoodID, &ln.BatchID, &ln.CellID, &ln.LoadUnitID, &qty, &ln.Marks); err != nil {
			return nil, fmt.Errorf("разбор строки приёмки: %w", err)
		}
		ln.Qty, err = parseQty(qty)
		if err != nil {
			return nil, err
		}
		out = append(out, ln)
	}
	return out, rows.Err()
}

// ByID возвращает шапку документа.
func (r *ReceiptRepository) ByID(ctx context.Context, receiptID string) (model.Receipt, error) {
	var rc model.Receipt
	err := r.pool.QueryRow(ctx, `
		SELECT id::text, warehouse_id::text, supplier_id::text, status, created_by::text, posted_at, created_at,
		       doc_number, doc_date
		FROM receipts WHERE id = $1::uuid`, receiptID).
		Scan(&rc.ID, &rc.WarehouseID, &rc.SupplierID, &rc.Status, &rc.CreatedBy, &rc.PostedAt, &rc.CreatedAt,
			&rc.Doc.Number, &rc.Doc.Date)
	if errors.Is(err, pgx.ErrNoRows) {
		return model.Receipt{}, ErrReceiptNotFound
	}
	if err != nil {
		return model.Receipt{}, fmt.Errorf("прочитать приёмку: %w", err)
	}
	return rc, nil
}

// Lines возвращает строки документа с наименованием товара и адресом ячейки - для показа
// человеку. Оприходование пользуется внутренним listReceiptLines: ему нужны только идентификаторы.
func (r *ReceiptRepository) Lines(ctx context.Context, receiptID string) ([]model.ReceiptLine, error) {
	rows, err := r.pool.Query(ctx, `
		SELECT l.id::text, l.good_id::text, l.batch_id::text, l.cell_id::text, l.load_unit_id::text,
		       l.qty::text, g.name, c.address
		FROM receipt_lines l
		JOIN goods g ON g.id = l.good_id
		JOIN cells c ON c.id = l.cell_id
		WHERE l.receipt_id = $1::uuid
		ORDER BY l.created_at, l.id`, receiptID)
	if err != nil {
		return nil, fmt.Errorf("строки приёмки: %w", err)
	}
	defer rows.Close()

	out := make([]model.ReceiptLine, 0)
	for rows.Next() {
		var ln model.ReceiptLine
		var qty string
		if err := rows.Scan(&ln.ID, &ln.GoodID, &ln.BatchID, &ln.CellID, &ln.LoadUnitID,
			&qty, &ln.GoodName, &ln.CellAddress); err != nil {
			return nil, fmt.Errorf("разбор строки приёмки: %w", err)
		}
		ln.Qty, err = parseQty(qty)
		if err != nil {
			return nil, err
		}
		out = append(out, ln)
	}
	return out, rows.Err()
}

// parseQty разбирает numeric, пришедший из БД текстом, в decimal.
// Текстом - чтобы не потерять знаки: количества дробные (uom='кг'), а float округляет.
func parseQty(s string) (decimal.Decimal, error) {
	q, err := decimal.NewFromString(s)
	if err != nil {
		return decimal.Zero, fmt.Errorf("разобрать количество %q: %w", s, err)
	}
	return q, nil
}
