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

// Ошибки сессии ввода остатков.
var (
	// ErrSessionNotFound — нет сессии с таким id.
	ErrSessionNotFound = errors.New("stock entry session not found")
	// ErrSessionClosed — сессия уже финализирована (checkpoint/finalize по ней запрещены).
	ErrSessionClosed = errors.New("stock entry session already closed")
	// ErrSessionNotClosed — отчёт запрошен по ещё не завершённой сессии.
	ErrSessionNotClosed = errors.New("stock entry session not closed")
)

// StockEntryLineInput — строка ячейки в checkpoint'е. ProductionDate — ISO 'YYYY-MM-DD'
// (сервис уже привёл из транспортного DD-MM-YYYY).
type StockEntryLineInput struct {
	GoodID         string
	ProductionDate string
	Qty            decimal.Decimal
	// LoadUnitID — короб прохода, в котором лежит товар (ADHOC-46); пусто — россыпь.
	LoadUnitID string
	// Marks — марки ЧЗ строки (ADHOC-46): у маркируемого товара их ровно столько, сколько единиц.
	Marks []model.ReceiptMark
}

// StockEntryCellInput — ячейка прохода в checkpoint'е: строки, короба прохода, групповые
// упаковки ЧЗ (ADHOC-46) и новые привязки ШК.
type StockEntryCellInput struct {
	CellID    string
	Lines     []StockEntryLineInput
	LoadUnits []LoadUnitInput
	CZGroups  []model.CZAggregate
	Barcodes  []BarcodeBindInput
}

// BarcodeBindInput — новая привязка ШК, пришедшая с checkpoint'ом (коммитится в той же транзакции).
type BarcodeBindInput struct {
	GoodID    string
	Barcode   string
	Symbology string
	// FromCZMark — ШК пришёл из марки ЧЗ: привязка помечает товар маркируемым (CZ-05).
	FromCZMark bool
}

// StockEntryRepository — сессия ввода остатков (документ P-FS-01): создание, checkpoint ячейки,
// финализация с переносом в stock. Checkpoint/Finalize владеют транзакцией (как StockRepository.Transfer).
type StockEntryRepository struct {
	pool *pgxpool.Pool
}

// NewStockEntryRepository создаёт репозиторий сессий ввода остатков.
func NewStockEntryRepository(pool *pgxpool.Pool) *StockEntryRepository {
	return &StockEntryRepository{pool: pool}
}

// Create открывает новую сессию (status=draft) и возвращает её id.
func (r *StockEntryRepository) Create(ctx context.Context, warehouseID, createdBy string) (string, error) {
	var id string
	err := r.pool.QueryRow(ctx, `
		INSERT INTO stock_entry_sessions (warehouse_id, created_by)
		VALUES ($1::uuid, $2::uuid)
		RETURNING id::text`, warehouseID, createdBy).Scan(&id)
	if err != nil {
		return "", fmt.Errorf("create stock entry session: %w", err)
	}
	return id, nil
}

// CreateWithID открывает сессию с идентификатором, ВЫДАННЫМ УСТРОЙСТВОМ, и делает это
// идемпотентно: повторный вызов с тем же id возвращает ту же сессию, а не заводит вторую.
//
// Зачем идентификатор с устройства: checkpoint и финал адресуются по session_id, а без сети
// серверный идентификатор взять неоткуда — кладовщик начал бы проход и не смог бы его продолжить
// офлайн. Клиент генерирует UUID v4 сам (та же логика, что у operation_id в очереди, P2-03).
//
// Отвергнута альтернатива «весь проход одним батчем в конце»: она теряет частичный прогресс на
// плохой связи, а проход склада идёт часами.
func (r *StockEntryRepository) CreateWithID(ctx context.Context, sessionID, warehouseID, createdBy string) (string, error) {
	return createSessionWithID(ctx, r.pool, sessionID, warehouseID, createdBy)
}

// createSessionWithID — низкоуровневый старт сессии на Querier (пул или tx), чтобы старт из
// очереди коммитился в одной транзакции с пометкой операции (P2-05).
func createSessionWithID(ctx context.Context, q Querier, sessionID, warehouseID, createdBy string) (string, error) {
	var id string
	err := q.QueryRow(ctx, `
		INSERT INTO stock_entry_sessions (id, warehouse_id, created_by)
		VALUES ($1::uuid, $2::uuid, $3::uuid)
		ON CONFLICT (id) DO NOTHING
		RETURNING id::text`, sessionID, warehouseID, createdBy).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		// Сессия с таким id уже есть — это и есть повтор старта. Ни склад, ни автора не трогаем:
		// сессия уже в работе, и переписать их значило бы менять документ задним числом.
		return sessionID, nil
	}
	if err != nil {
		return "", fmt.Errorf("create stock entry session with id: %w", err)
	}
	return id, nil
}

// Checkpoint фиксирует ячейку в сессии: новые привязки ШК, затем содержимое ячейки — строки,
// короба и марки. Всё в одной транзакции. Сессия должна быть draft, иначе
// ErrSessionClosed/ErrSessionNotFound; плохие строки ячейки — *DocumentLinesError (ADHOC-46).
func (r *StockEntryRepository) Checkpoint(ctx context.Context, sessionID string, in StockEntryCellInput) error {
	return WithinTx(ctx, r.pool, func(q Querier) error {
		return checkpointCell(ctx, q, sessionID, in)
	})
}

// checkpointCell — checkpoint на Querier: им пользуются и прямая ручка, и операция очереди.
//
// Что: ячейка в сессии ЗАМЕНЯЕТСЯ присланной — прежние строки, короба, упаковки и марки этой
// ячейки удаляются, присланные записываются (ADHOC-46).
// Зачем: повторный checkpoint — это исправленная после отказа ячейка или ретрай, и строка,
// убранная с ТСД, не должна остаться в сессии. Удаление идёт до проверки отказов: иначе
// прежний вариант ячейки выглядел бы «тем же коробом в другой ячейке прохода».
func checkpointCell(ctx context.Context, q Querier, sessionID string, in StockEntryCellInput) error {
	if err := guardSessionDraft(ctx, q, sessionID); err != nil {
		return err
	}
	// Привязки ШК — до строк: строка может ссылаться на товар только что привязанного ШК.
	for _, b := range in.Barcodes {
		if err := bindBarcode(ctx, q, b.GoodID, b.Barcode, b.Symbology); err != nil {
			return err
		}
	}
	if err := clearSessionCell(ctx, q, sessionID, in.CellID); err != nil {
		return err
	}
	if err := guardEntryCell(ctx, q, sessionID, in, true); err != nil {
		return err
	}
	if err := insertSessionCZ(ctx, q, sessionID, in); err != nil {
		return err
	}
	for _, ln := range in.Lines {
		lineID, err := upsertSessionLine(ctx, q, sessionID, in.CellID, ln)
		if err != nil {
			return err
		}
		if err := insertSessionMarks(ctx, q, sessionID, lineID, ln.Marks); err != nil {
			return err
		}
	}
	return nil
}

// Finalize переносит все строки сессии в stock (SET) и закрывает сессию — в одной транзакции.
// Возвращает число записанных строк. Повтор по закрытой сессии → ErrSessionClosed.
func (r *StockEntryRepository) Finalize(ctx context.Context, sessionID string) (int, error) {
	var written int
	err := WithinTx(ctx, r.pool, func(q Querier) error {
		var err error
		written, err = finalizeSession(ctx, q, sessionID)
		return err
	})
	if err != nil {
		return 0, err
	}
	return written, nil
}

// finalizeSession — низкоуровневый финал на Querier: содержимое сессии → склад + закрытие.
// Вынесен, чтобы финал из очереди шёл в одной транзакции с пометкой операции (P2-05).
//
// Порядок (ADHOC-46): отказы → ГЕ прохода → SET остатка граней → состав и размещение коробов →
// марки, упаковки и проблемы ЧЗ. SET считается до размещения коробов прохода: в сумму «короба,
// уже лежащие в ячейке» они попасть не должны — их состав уже в строках сессии.
func finalizeSession(ctx context.Context, q Querier, sessionID string) (int, error) {
	if err := guardSessionDraft(ctx, q, sessionID); err != nil {
		return 0, err
	}
	cells, err := loadSessionCells(ctx, q, sessionID)
	if err != nil {
		return 0, err
	}
	// Между checkpoint и финалом короб или марку могла завести приёмка — проверка повторяется
	// под транзакцией финала.
	if err := guardSessionCells(ctx, q, sessionID, cells); err != nil {
		return 0, err
	}
	// Ввод остатков приходует в склад по умолчанию: выбор учётной принадлежности сделан для
	// РАЗМЕЩЕНИЯ (P5), а проход склада фиксирует то, что физически лежит в ячейке.
	iwh, err := defaultInternalWarehouse(ctx, q)
	if err != nil {
		return 0, err
	}
	for _, c := range cells {
		for _, lu := range c.LoadUnits {
			if err := createLoadUnit(ctx, q, lu.ID, lu.Kind); err != nil {
				return 0, err
			}
		}
	}
	batches, written, err := setSessionStock(ctx, q, cells, iwh)
	if err != nil {
		return 0, err
	}
	if err := placeSessionBoxes(ctx, q, sessionID, cells, batches); err != nil {
		return 0, err
	}
	if err := receiveSessionCZ(ctx, q, sessionID, cells); err != nil {
		return 0, err
	}
	if _, err := q.Exec(ctx, `
		UPDATE stock_entry_sessions SET status='closed', closed_at=now()
		WHERE id = $1::uuid`, sessionID); err != nil {
		return 0, fmt.Errorf("close session: %w", err)
	}

	// Снимок документа — в ЭТОЙ ЖЕ транзакции (P3-01): закрытая сессия без документа невозможна,
	// как и документ по незакрытой. Снимается ПОСЛЕ закрытия, но до коммита — строки сессии
	// к этому моменту окончательны.
	snap, err := buildStockEntrySnapshot(ctx, q, sessionID)
	if err != nil {
		return 0, err
	}
	documentID, err := saveDocument(ctx, q, model.ReportDocument{
		Kind:       model.ReportKindStockEntry,
		SourceType: model.SourceTypeStockEntrySession,
		SourceID:   sessionID,
		Snapshot:   snap,
	})
	if err != nil {
		return 0, err
	}

	// Журнал документа начинается здесь (P3-03). Пустой id — повтор финала: документ уже был,
	// и второе событие «сформирован» означало бы, что его сформировали дважды.
	// Автор — тот, кто вёл проход: у документа нет собственного создателя, он рождается операцией.
	if documentID != "" {
		var author string
		if err := q.QueryRow(ctx,
			`SELECT created_by::text FROM stock_entry_sessions WHERE id = $1::uuid`, sessionID).Scan(&author); err != nil {
			return 0, fmt.Errorf("автор сессии для журнала: %w", err)
		}
		if err := logEvent(ctx, q, documentID, model.DocEventCreated, author, ""); err != nil {
			return 0, err
		}
	}
	return written, nil
}

// buildStockEntrySnapshot собирает содержимое документа по данным сессии — ровно то, что раньше
// собирал Report на каждое скачивание. Вызывается один раз, в транзакции финала: справочники
// читаются на момент завершения операции, и дальше документ от них не зависит.
func buildStockEntrySnapshot(ctx context.Context, q Querier, sessionID string) (model.ReportSnapshot, error) {
	var snap model.ReportSnapshot
	if err := q.QueryRow(ctx, `
		SELECT w.code, w.name, s.created_at, s.number
		FROM stock_entry_sessions s
		JOIN warehouses w ON w.id = s.warehouse_id
		WHERE s.id = $1::uuid`, sessionID).
		Scan(&snap.WarehouseCode, &snap.WarehouseName, &snap.CreatedAt, &snap.SourceNumber); err != nil {
		return model.ReportSnapshot{}, fmt.Errorf("снимок документа, шапка: %w", err)
	}

	// Строка документа — грань остатка: россыпь и короба прохода одного товара и партии в ячейке
	// сводятся в одну строку (ADHOC-46) — в 1С короба нет, есть количество в ячейке.
	// Марки ЧЗ строк прохода (ADHOC-55) — в документ строкой на марку.
	rows, err := q.Query(ctx, `
		SELECT c.address, g.code, g.name, l.production_date::text, sum(l.qty)::text,
		       COALESCE((SELECT array_agg(m.cis)
		                 FROM stock_entry_marks m
		                 JOIN stock_entry_lines ml ON ml.id = m.line_id
		                 WHERE m.session_id = $1::uuid AND ml.cell_id = l.cell_id
		                   AND ml.good_id = l.good_id AND ml.production_date = l.production_date),
		                '{}')
		FROM stock_entry_lines l
		JOIN cells c ON c.id = l.cell_id
		JOIN goods g ON g.id = l.good_id
		WHERE l.session_id = $1::uuid
		GROUP BY l.cell_id, l.good_id, c.address, g.code, g.name, l.production_date
		ORDER BY c.address, g.name`, sessionID)
	if err != nil {
		return model.ReportSnapshot{}, fmt.Errorf("снимок документа, строки: %w", err)
	}
	defer rows.Close()
	snap.Rows = make([]model.ReportSnapshotRow, 0)
	for rows.Next() {
		var row model.ReportSnapshotRow
		var qty string
		var marks []string
		if err := rows.Scan(&row.CellAddress, &row.GoodCode, &row.GoodName, &row.ProductionDate, &qty, &marks); err != nil {
			return model.ReportSnapshot{}, fmt.Errorf("снимок документа, разбор строки: %w", err)
		}
		if len(marks) == 0 {
			row.Qty = qty
			snap.Rows = append(snap.Rows, row)
			continue
		}
		n, err := parseQty(qty)
		if err != nil {
			return model.ReportSnapshot{}, err
		}
		snap.Rows = append(snap.Rows, splitByMarks(row, n, marks)...)
	}
	return snap, rows.Err()
}

// guardSessionDraft проверяет, что сессия существует и ещё в работе (draft).
func guardSessionDraft(ctx context.Context, q Querier, sessionID string) error {
	var status string
	err := q.QueryRow(ctx, `SELECT status FROM stock_entry_sessions WHERE id = $1::uuid`, sessionID).Scan(&status)
	if errors.Is(err, pgx.ErrNoRows) {
		return ErrSessionNotFound
	}
	if err != nil {
		return fmt.Errorf("session status: %w", err)
	}
	if status != "draft" {
		return ErrSessionClosed
	}
	return nil
}

// upsertSessionLine записывает строку ячейки и возвращает её id. Грань строки — (сессия, ячейка,
// товар, партия, короб); ячейка перед записью очищена (checkpointCell), поэтому совпадение грани
// — повтор той же грани в одном теле, и количества складываются: марки обеих строк ложатся на
// одну строку сессии, и её количество должно сойтись с их числом.
func upsertSessionLine(ctx context.Context, q Querier, sessionID, cellID string, ln StockEntryLineInput) (string, error) {
	var id string
	err := q.QueryRow(ctx, `
		INSERT INTO stock_entry_lines (session_id, cell_id, good_id, production_date, qty, load_unit_id)
		VALUES ($1::uuid, $2::uuid, $3::uuid, $4::date, $5::numeric, NULLIF($6, '')::uuid)
		ON CONFLICT (session_id, cell_id, good_id, production_date, load_unit_id)
		DO UPDATE SET qty = stock_entry_lines.qty + EXCLUDED.qty
		RETURNING id::text`,
		sessionID, cellID, ln.GoodID, ln.ProductionDate, ln.Qty.String(), ln.LoadUnitID).Scan(&id)
	if err != nil {
		return "", fmt.Errorf("upsert session line: %w", err)
	}
	return id, nil
}
