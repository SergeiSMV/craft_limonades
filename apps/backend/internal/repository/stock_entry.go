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
}

// BarcodeBindInput — новая привязка ШК, пришедшая с checkpoint'ом (коммитится в той же транзакции).
type BarcodeBindInput struct {
	GoodID    string
	Barcode   string
	Symbology string
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

// Checkpoint фиксирует ячейку в сессии: новые привязки ШК + строки (upsert-SET по грани). Всё в
// одной транзакции. Сессия должна быть draft, иначе ErrSessionClosed/ErrSessionNotFound.
func (r *StockEntryRepository) Checkpoint(ctx context.Context, sessionID, cellID string, lines []StockEntryLineInput, barcodes []BarcodeBindInput) error {
	return WithinTx(ctx, r.pool, func(q Querier) error {
		if err := guardSessionDraft(ctx, q, sessionID); err != nil {
			return err
		}
		// Привязки ШК — до строк: строка может ссылаться на товар только что привязанного ШК.
		for _, b := range barcodes {
			if err := bindBarcode(ctx, q, b.GoodID, b.Barcode, b.Symbology); err != nil {
				return err
			}
		}
		for _, ln := range lines {
			if err := upsertSessionLine(ctx, q, sessionID, cellID, ln.GoodID, ln.ProductionDate, ln.Qty); err != nil {
				return err
			}
		}
		return nil
	})
}

// Finalize переносит все строки сессии в stock (SET) и закрывает сессию — в одной транзакции.
// Возвращает число записанных строк. Повтор по закрытой сессии → ErrSessionClosed.
func (r *StockEntryRepository) Finalize(ctx context.Context, sessionID string) (int, error) {
	var written int
	err := WithinTx(ctx, r.pool, func(q Querier) error {
		if err := guardSessionDraft(ctx, q, sessionID); err != nil {
			return err
		}
		lines, err := listSessionLines(ctx, q, sessionID)
		if err != nil {
			return err
		}
		// По каждой строке: партия GetOrCreate (P-FS-02) → SET остатка (P-FS-02).
		for _, ln := range lines {
			batchID, err := getOrCreateBatch(ctx, q, ln.goodID, ln.productionDate)
			if err != nil {
				return err
			}
			key := model.StockKey{CellID: ln.cellID, GoodID: ln.goodID, BatchID: batchID}
			if err := setStock(ctx, q, key, ln.qty); err != nil {
				return err
			}
			written++
		}
		if _, err := q.Exec(ctx, `
			UPDATE stock_entry_sessions SET status='closed', closed_at=now()
			WHERE id = $1::uuid`, sessionID); err != nil {
			return fmt.Errorf("close session: %w", err)
		}
		return nil
	})
	if err != nil {
		return 0, err
	}
	return written, nil
}

// Report собирает данные отчёта «ввод остатков» по ЗАКРЫТОЙ сессии: шапка (склад, время) + строки
// (ячейка · товар · партия · кол-во). Нет сессии → ErrSessionNotFound; не закрыта → ErrSessionNotClosed.
func (r *StockEntryRepository) Report(ctx context.Context, sessionID string) (model.StockEntryReport, error) {
	var rep model.StockEntryReport
	var status string
	err := r.pool.QueryRow(ctx, `
		SELECT s.status, w.code, w.name, s.created_at
		FROM stock_entry_sessions s
		JOIN warehouses w ON w.id = s.warehouse_id
		WHERE s.id = $1::uuid`, sessionID).
		Scan(&status, &rep.WarehouseCode, &rep.WarehouseName, &rep.CreatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return model.StockEntryReport{}, ErrSessionNotFound
	}
	if err != nil {
		return model.StockEntryReport{}, fmt.Errorf("stock entry report meta: %w", err)
	}
	if status != "closed" {
		return model.StockEntryReport{}, ErrSessionNotClosed
	}

	rows, err := r.pool.Query(ctx, `
		SELECT c.address, g.code, g.name, l.production_date::text, l.qty::text
		FROM stock_entry_lines l
		JOIN cells c ON c.id = l.cell_id
		JOIN goods g ON g.id = l.good_id
		WHERE l.session_id = $1::uuid
		ORDER BY c.address, g.name`, sessionID)
	if err != nil {
		return model.StockEntryReport{}, fmt.Errorf("stock entry report rows: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var row model.StockEntryReportRow
		if err := rows.Scan(&row.CellAddress, &row.GoodCode, &row.GoodName, &row.ProductionDate, &row.Qty); err != nil {
			return model.StockEntryReport{}, fmt.Errorf("scan report row: %w", err)
		}
		rep.Rows = append(rep.Rows, row)
	}
	return rep, rows.Err()
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

// upsertSessionLine — SET-семантика внутри сессии: грань (session,cell,good,date) уникальна,
// повторный checkpoint той же грани перезаписывает количество.
func upsertSessionLine(ctx context.Context, q Querier, sessionID, cellID, goodID, productionDate string, qty decimal.Decimal) error {
	_, err := q.Exec(ctx, `
		INSERT INTO stock_entry_lines (session_id, cell_id, good_id, production_date, qty)
		VALUES ($1::uuid, $2::uuid, $3::uuid, $4::date, $5::numeric)
		ON CONFLICT (session_id, cell_id, good_id, production_date)
		DO UPDATE SET qty = EXCLUDED.qty`,
		sessionID, cellID, goodID, productionDate, qty.String())
	if err != nil {
		return fmt.Errorf("upsert session line: %w", err)
	}
	return nil
}

// sessionLine — строка сессии для финала (внутренняя).
type sessionLine struct {
	cellID         string
	goodID         string
	productionDate string // ISO 'YYYY-MM-DD'
	qty            decimal.Decimal
}

// listSessionLines читает все строки сессии. Rows вычитываем полностью в срез до следующих
// запросов (на одном соединении tx нельзя держать открытый Rows и параллельно исполнять запросы).
func listSessionLines(ctx context.Context, q Querier, sessionID string) ([]sessionLine, error) {
	rows, err := q.Query(ctx, `
		SELECT cell_id::text, good_id::text, production_date::text, qty::text
		FROM stock_entry_lines WHERE session_id = $1::uuid`, sessionID)
	if err != nil {
		return nil, fmt.Errorf("list session lines: %w", err)
	}
	defer rows.Close()

	var out []sessionLine
	for rows.Next() {
		var l sessionLine
		var qtyStr string
		if err := rows.Scan(&l.cellID, &l.goodID, &l.productionDate, &qtyStr); err != nil {
			return nil, fmt.Errorf("scan session line: %w", err)
		}
		l.qty, err = decimal.NewFromString(qtyStr)
		if err != nil {
			return nil, fmt.Errorf("parse qty %q: %w", qtyStr, err)
		}
		out = append(out, l)
	}
	return out, rows.Err()
}
