package repository

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/shopspring/decimal"

	"craftwms/internal/model"
)

// Ошибки переноса ГЕ и проведения документа движения (P6-02). Все — отказ по существу:
// повтор их не исправит.
var (
	// ErrSameCell — ГЕ переносят туда, где она и так лежит.
	ErrSameCell = errors.New("load unit is already in the target cell")
	// ErrMovementPosted — документ движения с этим идентификатором уже проведён.
	ErrMovementPosted = errors.New("movement already posted")
	// ErrEmptyMovement — в документе движения нет ни одной строки.
	ErrEmptyMovement = errors.New("movement has no lines")
	// ErrUnknownMovementKind — вид документа не перемещение и не пополнение.
	ErrUnknownMovementKind = errors.New("unknown movement kind")
	// ErrLoadUnitNotMoved — ГЕ целиком едет только перемещением: пополнение двигает товар.
	ErrLoadUnitNotMoved = errors.New("whole load unit moves only by a move document")
	// ErrEmptyMovementLine — в строке нет ГЕ. Ветка товара появится в P6-03.
	ErrEmptyMovementLine = errors.New("movement line has no load unit")
)

// loadUnitTransfer — что нужно, чтобы перенести ГЕ целиком в другую ячейку.
type loadUnitTransfer struct {
	LoadUnitID  string
	ToCellID    string
	WarehouseID string // склад документа: обе ячейки обязаны принадлежать ему
	// Учётная принадлежность состава. Короба на складе лежат в «Основном» — приёмка и
	// размещение кладут туда (уточнение ADR-0016); брак коробом не изолируется.
	InternalWarehouseID string

	// Для журнала размещений: кто и каким документом перенёс.
	Source     string
	UserID     string
	PutawayID  *string
	MovementID *string
}

// transferLoadUnit переносит ГЕ целиком: остаток по её составу переезжает из ячейки, где ГЕ
// числится, в целевую, а место ГЕ и журнал меняет placeLoadUnit (P6-02).
//
// Что: единая функция переноса короба — её зовут размещение (P5-02) и перемещение (P6).
// Зачем: состав ГЕ лежит в остатке её ячейки (приёмка кладёт их вместе), и перенос короба без
//
//	остатка разорвал бы «что в коробе» и «что в ячейке». Две копии этой логики разошлись бы.
//
// Как: строка ГЕ блокируется (FOR UPDATE), состав читается здесь же, в транзакции операции —
//
//	он и есть то, что физически переехало. Остаток двигают общие примитивы stock: через них
//	проходит любое изменение остатка, и проверку пересчёта (P10) добавят в одном месте.
//	Возвращает ячейку, откуда ГЕ взяли.
func transferLoadUnit(ctx context.Context, q Querier, in loadUnitTransfer) (string, error) {
	var from *string
	var parent *string
	var hasChildren bool
	err := q.QueryRow(ctx, `
		SELECT cell_id::text, parent_id::text,
		       EXISTS (SELECT 1 FROM load_units c WHERE c.parent_id = lu.id)
		FROM load_units lu WHERE id = $1::uuid FOR UPDATE`, in.LoadUnitID).
		Scan(&from, &parent, &hasChildren)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", ErrLoadUnitNotFound
	}
	if err != nil {
		return "", fmt.Errorf("прочитать ГЕ: %w", err)
	}
	if from == nil {
		return "", ErrLoadUnitNotPlaced
	}
	// Паллетная логика вне объёма пилота: перенос части дерева разорвал бы место коробов
	// и их остаток.
	if parent != nil || hasChildren {
		return "", ErrLoadUnitNested
	}
	if *from == in.ToCellID {
		return "", ErrSameCell
	}
	if err := guardCellOfWarehouse(ctx, q, in.ToCellID, in.WarehouseID); err != nil {
		return "", err
	}
	if err := guardCellOfWarehouse(ctx, q, *from, in.WarehouseID); err != nil {
		return "", err
	}

	items, err := loadUnitStock(ctx, q, in.LoadUnitID)
	if err != nil {
		return "", err
	}
	for _, c := range items {
		if err := transferStock(ctx, q,
			model.StockKey{CellID: *from, GoodID: c.good, BatchID: c.batch, InternalWarehouseID: in.InternalWarehouseID},
			model.StockKey{CellID: in.ToCellID, GoodID: c.good, BatchID: c.batch, InternalWarehouseID: in.InternalWarehouseID},
			c.qty); err != nil {
			return "", err
		}
	}

	if err := placeLoadUnit(ctx, q, model.PlaceLoadUnitInput{
		LoadUnitID: in.LoadUnitID,
		CellID:     in.ToCellID,
		Source:     in.Source,
		UserID:     in.UserID,
		PutawayID:  in.PutawayID,
		MovementID: in.MovementID,
	}); err != nil {
		return "", err
	}
	return *from, nil
}

// luStockItem — позиция состава ГЕ: товар, партия, количество.
type luStockItem struct {
	good, batch string
	qty         decimal.Decimal
}

// loadUnitStock читает непустой состав ГЕ. Строки читаются целиком до переноса: курсор
// и запись остатка в одной транзакции на одном соединении не уживаются.
func loadUnitStock(ctx context.Context, q Querier, loadUnitID string) ([]luStockItem, error) {
	rows, err := q.Query(ctx, `
		SELECT good_id::text, batch_id::text, qty::text
		FROM lu_content WHERE load_unit_id = $1::uuid AND qty > 0`, loadUnitID)
	if err != nil {
		return nil, fmt.Errorf("прочитать состав ГЕ: %w", err)
	}
	defer rows.Close()

	var items []luStockItem
	for rows.Next() {
		var c luStockItem
		var qty string
		if err := rows.Scan(&c.good, &c.batch, &qty); err != nil {
			return nil, fmt.Errorf("разобрать состав ГЕ: %w", err)
		}
		if c.qty, err = decimal.NewFromString(qty); err != nil {
			return nil, fmt.Errorf("количество в составе ГЕ: %w", err)
		}
		items = append(items, c)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("прочитать состав ГЕ: %w", err)
	}
	return items, nil
}

// MovementLineInput — строка документа движения. Пока только ГЕ целиком; ветка товара
// (из ячейки или короба в ячейку или короб) появится в P6-03.
type MovementLineInput struct {
	LoadUnitID string
	ToCellID   string
}

// MovementSubmitInput — документ движения, собранный устройством целиком (P6-01).
type MovementSubmitInput struct {
	MovementID  string
	Kind        string // model.MovementMove | model.MovementReplenish
	WarehouseID string
	CreatedBy   string
	Lines       []MovementLineInput
}

// movementSubmit проводит документ движения целиком на Querier (P6-02).
//
// Что: шапка документа и строки; ГЕ целиком переезжает вместе с остатком по составу.
// Зачем одной транзакцией: документ — одно «Движение» для 1С; отклонённая строка в цепочке
//
//	дала бы проведённый документ без неё — тот же урок, что у приёмки и размещения.
//
// Как: строки идут по порядку ТСД; любая ошибка откатывает весь документ. Повтор с тем же
//
//	документом упирается в первичный ключ и даёт ErrMovementPosted. Одну ГЕ можно перенести
//	в документе дважды (A → B → C): вторая строка берёт её оттуда, куда положила первая.
func movementSubmit(ctx context.Context, q Querier, in MovementSubmitInput) (int, error) {
	if in.Kind != model.MovementMove && in.Kind != model.MovementReplenish {
		return 0, ErrUnknownMovementKind
	}
	if len(in.Lines) == 0 {
		return 0, ErrEmptyMovement
	}
	if _, err := q.Exec(ctx, `
		INSERT INTO movements (id, kind, warehouse_id, created_by)
		VALUES ($1::uuid, $2, $3::uuid, $4::uuid)`,
		in.MovementID, in.Kind, in.WarehouseID, in.CreatedBy); err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" {
			return 0, ErrMovementPosted
		}
		return 0, fmt.Errorf("открыть документ движения: %w", err)
	}

	iwh, err := defaultInternalWarehouse(ctx, q)
	if err != nil {
		return 0, err
	}
	for i, ln := range in.Lines {
		if ln.LoadUnitID == "" {
			return 0, ErrEmptyMovementLine
		}
		if in.Kind != model.MovementMove {
			return 0, ErrLoadUnitNotMoved
		}
		from, err := transferLoadUnit(ctx, q, loadUnitTransfer{
			LoadUnitID:          ln.LoadUnitID,
			ToCellID:            ln.ToCellID,
			WarehouseID:         in.WarehouseID,
			InternalWarehouseID: iwh,
			Source:              model.PlacementMove,
			UserID:              in.CreatedBy,
			MovementID:          &in.MovementID,
		})
		if err != nil {
			return 0, err
		}
		if _, err := q.Exec(ctx, `
			INSERT INTO movement_lines (movement_id, line_no, load_unit_id, from_cell_id, to_cell_id)
			VALUES ($1::uuid, $2, $3::uuid, $4::uuid, $5::uuid)`,
			in.MovementID, i+1, ln.LoadUnitID, from, ln.ToCellID); err != nil {
			return 0, fmt.Errorf("записать строку движения: %w", err)
		}
	}
	return len(in.Lines), nil
}
