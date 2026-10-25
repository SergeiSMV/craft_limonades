package service

import (
	"context"
	"encoding/json"
	"errors"
	"strings"

	"github.com/google/uuid"
	"github.com/shopspring/decimal"

	"craftwms/internal/model"
	"craftwms/internal/repository"
)

// MaxBatchOperations — потолок операций в одном батче.
//
// Зачем потолок: батч исполняется по одной транзакции на операцию, и неограниченный список
// держал бы соединение пула столько, сколько устройство сочтёт нужным прислать. Сто операций
// покрывают самый длинный реальный случай (проход склада с накопленной за смену очередью).
const MaxBatchOperations = 100

// Исходы операции в батче.
const (
	// StatusAccepted — операция применена сейчас.
	StatusAccepted = "accepted"
	// StatusDuplicate — операция уже применялась раньше; эффект не повторялся.
	StatusDuplicate = "duplicate"
	// StatusRejected — сервер отказал по существу: повтор не поможет, нужен разбор человеком.
	StatusRejected = "rejected"
)

// Ошибки батча операций.
var (
	// ErrEmptyBatch — прислан пустой список операций.
	ErrEmptyBatch = errors.New("operations list is empty")
	// ErrBatchTooLarge — операций больше MaxBatchOperations.
	ErrBatchTooLarge = errors.New("too many operations in one batch")
	// ErrInvalidOperationID — operation_id не UUID.
	ErrInvalidOperationID = errors.New("operation_id must be a UUID")
	// ErrUnknownKind — сервер не знает такого типа операции.
	ErrUnknownKind = errors.New("unknown operation kind")
	// ErrInvalidPayload — тело операции не разбирается или неполно.
	ErrInvalidPayload = errors.New("invalid operation payload")
)

// Operation — операция, пришедшая из очереди устройства.
type Operation struct {
	OperationID string          `json:"operation_id"`
	Kind        string          `json:"kind"`
	Payload     json.RawMessage `json:"payload"`
}

// OperationResult — исход одной операции батча.
type OperationResult struct {
	OperationID string          `json:"operation_id"`
	Status      string          `json:"status"`
	Error       string          `json:"error,omitempty"`
	Result      json.RawMessage `json:"result,omitempty"`
}

// operationsRepo — зависимость сервиса от применения операций (интерфейс ради тестируемости).
type operationsRepo interface {
	BindBarcode(ctx context.Context, operationID string, in repository.BarcodeBindInput) (repository.Applied, error)
	UnbindBarcode(ctx context.Context, operationID, barcode string) (repository.Applied, error)
	StockEntryStart(ctx context.Context, operationID, sessionID, warehouseID, createdBy string) (repository.Applied, error)
	StockEntryCheckpoint(ctx context.Context, operationID, sessionID, cellID string, lines []repository.StockEntryLineInput, barcodes []repository.BarcodeBindInput) (repository.Applied, error)
	StockEntryFinalize(ctx context.Context, operationID, sessionID string) (repository.Applied, error)
	ReceiptSubmit(ctx context.Context, operationID string, in repository.ReceiptSubmitInput) (repository.Applied, error)
	PutawaySubmit(ctx context.Context, operationID string, in repository.PutawaySubmitInput) (repository.Applied, error)
	MovementSubmit(ctx context.Context, operationID string, in repository.MovementSubmitInput) (repository.Applied, error)
	ProblemSubmit(ctx context.Context, operationID string, in repository.ProblemSubmitInput) (repository.Applied, error)
	ReturnSubmit(ctx context.Context, operationID string, in repository.ReturnSubmitInput) (repository.Applied, error)
}

// OperationsService — приём батча операций из очереди устройства с дедупом по operation_id.
//
// Что: разбирает список операций, применяет их ПО ПОРЯДКУ и возвращает исход каждой.
// Зачем: очередь устройства повторяет операции до подтверждения, и сервер обязан отличать
//
//	«сделай» от «ты это уже делал» — иначе повтор удваивает эффект (P2-05).
//
// Как: каждая операция уходит в репозиторий со своим ключом идемпотентности; эффект и пометка
//
//	коммитятся одной транзакцией.
type OperationsService struct {
	repo operationsRepo
}

// NewOperationsService собирает сервис приёма операций.
func NewOperationsService(repo operationsRepo) *OperationsService {
	return &OperationsService{repo: repo}
}

// Apply применяет батч операций по порядку и возвращает исход каждой.
//
// ⚠ Батч — НЕ одна транзакция. Транзакция у каждой операции своя, и это осознанно: одна операция,
// отклонённая по существу (ШК уже за другим товаром), откатила бы вместе с собой все успешные
// перед ней, и очередь устройства не смогла бы протолкнуться дальше неисполнимой операции —
// встала бы навсегда. Атомарность нужна между эффектом и его пометкой, а не между чужими
// друг другу операциями.
//
// ⚠ Порядок соблюдается строго, и на первой ВРЕМЕННОЙ неудаче (недоступна БД, сбой соединения)
// разбор батча прекращается: результатов возвращается меньше, чем прислано операций. Оставшиеся
// устройство пришлёт снова. Перескочить через застрявшую операцию нельзя — «привязать» и
// «отвязать» один ШК в обратном порядке дают противоположный итог.
func (s *OperationsService) Apply(ctx context.Context, userID string, ops []Operation) ([]OperationResult, error) {
	if len(ops) == 0 {
		return nil, ErrEmptyBatch
	}
	if len(ops) > MaxBatchOperations {
		return nil, ErrBatchTooLarge
	}

	results := make([]OperationResult, 0, len(ops))
	for _, op := range ops {
		res, temporary := s.applyOne(ctx, userID, op)
		if temporary != nil {
			// Прерываем разбор: всё, что уже применено, возвращаем — эти операции устройство
			// снимет с очереди и не пришлёт повторно.
			if len(results) == 0 {
				return nil, temporary
			}
			return results, nil
		}
		results = append(results, res)
	}
	return results, nil
}

// applyOne применяет одну операцию. Второе возвращаемое значение — ВРЕМЕННАЯ ошибка (повод
// прервать батч); отказ по существу приходит в OperationResult со статусом rejected.
func (s *OperationsService) applyOne(ctx context.Context, userID string, op Operation) (OperationResult, error) {
	id := strings.TrimSpace(op.OperationID)
	if _, err := uuid.Parse(id); err != nil {
		return rejected(op.OperationID, ErrInvalidOperationID), nil
	}

	applied, err := s.dispatch(ctx, userID, id, op)
	switch {
	case err == nil:
		status := StatusAccepted
		if applied.Duplicate {
			status = StatusDuplicate
		}
		return OperationResult{OperationID: id, Status: status, Result: applied.Result}, nil
	case isRejection(err):
		return rejected(id, err), nil
	default:
		return OperationResult{}, err
	}
}

// dispatch выбирает эффект по типу операции и разбирает его тело.
func (s *OperationsService) dispatch(ctx context.Context, userID, id string, op Operation) (repository.Applied, error) {
	switch op.Kind {
	case repository.KindBindBarcode:
		var p struct {
			GoodID    string `json:"good_id"`
			Barcode   string `json:"barcode"`
			Symbology string `json:"symbology"`
			// FromCZMark — ШК пришёл из марки ЧЗ (CZ-05): привязка заодно помечает товар
			// маркируемым (долг 16, признак по факту). Старые клиенты поле не шлют — false.
			FromCZMark bool `json:"from_cz_mark"`
		}
		if err := json.Unmarshal(op.Payload, &p); err != nil {
			return repository.Applied{}, ErrInvalidPayload
		}
		goodID := strings.TrimSpace(p.GoodID)
		code := strings.TrimSpace(p.Barcode)
		if goodID == "" {
			return repository.Applied{}, ErrEmptyGoodID
		}
		if code == "" {
			return repository.Applied{}, ErrEmptyBarcode
		}
		return s.repo.BindBarcode(ctx, id, repository.BarcodeBindInput{
			GoodID: goodID, Barcode: code, Symbology: strings.TrimSpace(p.Symbology),
			FromCZMark: p.FromCZMark,
		})

	case repository.KindUnbindBarcode:
		var p struct {
			Barcode string `json:"barcode"`
		}
		if err := json.Unmarshal(op.Payload, &p); err != nil {
			return repository.Applied{}, ErrInvalidPayload
		}
		code := strings.TrimSpace(p.Barcode)
		if code == "" {
			return repository.Applied{}, ErrEmptyBarcode
		}
		return s.repo.UnbindBarcode(ctx, id, code)

	case repository.KindStockEntryStart:
		var p struct {
			SessionID   string `json:"session_id"`
			WarehouseID string `json:"warehouse_id"`
		}
		if err := json.Unmarshal(op.Payload, &p); err != nil {
			return repository.Applied{}, ErrInvalidPayload
		}
		sessionID := strings.TrimSpace(p.SessionID)
		warehouseID := strings.TrimSpace(p.WarehouseID)
		if warehouseID == "" {
			return repository.Applied{}, ErrEmptyWarehouse
		}
		// Идентификатор сессии здесь обязателен, в отличие от прямой ручки: операция очереди
		// адресуется по нему офлайн, и «выдай сам» лишило бы смысла саму постановку в очередь.
		if _, err := uuid.Parse(sessionID); err != nil {
			return repository.Applied{}, ErrInvalidSessionID
		}
		// Автор — из токена, а не из тела: иначе устройство могло бы записать проход на другого.
		return s.repo.StockEntryStart(ctx, id, sessionID, warehouseID, userID)

	case repository.KindStockEntryCheckpoint:
		var p struct {
			SessionID string `json:"session_id"`
			CellID    string `json:"cell_id"`
			Lines     []struct {
				GoodID         string          `json:"good_id"`
				ProductionDate string          `json:"production_date"`
				Qty            decimal.Decimal `json:"qty"`
			} `json:"lines"`
			NewBarcodes []struct {
				GoodID    string `json:"good_id"`
				Barcode   string `json:"barcode"`
				Symbology string `json:"symbology"`
			} `json:"new_barcodes"`
		}
		if err := json.Unmarshal(op.Payload, &p); err != nil {
			return repository.Applied{}, ErrInvalidPayload
		}
		sessionID := strings.TrimSpace(p.SessionID)
		cellID := strings.TrimSpace(p.CellID)
		if _, err := uuid.Parse(sessionID); err != nil {
			return repository.Applied{}, ErrInvalidSessionID
		}
		if cellID == "" {
			return repository.Applied{}, ErrEmptyCell
		}
		lines := make([]repository.StockEntryLineInput, 0, len(p.Lines))
		for _, ln := range p.Lines {
			goodID := strings.TrimSpace(ln.GoodID)
			if goodID == "" {
				return repository.Applied{}, ErrEmptyGoodID
			}
			if ln.Qty.IsNegative() {
				return repository.Applied{}, ErrInvalidQuantity
			}
			iso, err := parseEntryDate(ln.ProductionDate)
			if err != nil {
				return repository.Applied{}, err
			}
			lines = append(lines, repository.StockEntryLineInput{GoodID: goodID, ProductionDate: iso, Qty: ln.Qty})
		}
		binds := make([]repository.BarcodeBindInput, 0, len(p.NewBarcodes))
		for _, b := range p.NewBarcodes {
			goodID := strings.TrimSpace(b.GoodID)
			code := strings.TrimSpace(b.Barcode)
			if goodID == "" {
				return repository.Applied{}, ErrEmptyGoodID
			}
			if code == "" {
				return repository.Applied{}, ErrEmptyBarcode
			}
			binds = append(binds, repository.BarcodeBindInput{GoodID: goodID, Barcode: code, Symbology: strings.TrimSpace(b.Symbology)})
		}
		return s.repo.StockEntryCheckpoint(ctx, id, sessionID, cellID, lines, binds)

	case repository.KindStockEntryFinalize:
		var p struct {
			SessionID string `json:"session_id"`
		}
		if err := json.Unmarshal(op.Payload, &p); err != nil {
			return repository.Applied{}, ErrInvalidPayload
		}
		sessionID := strings.TrimSpace(p.SessionID)
		if _, err := uuid.Parse(sessionID); err != nil {
			return repository.Applied{}, ErrInvalidSessionID
		}
		return s.repo.StockEntryFinalize(ctx, id, sessionID)

	case repository.KindReceiptSubmit:
		return s.receiptSubmit(ctx, userID, id, op.Payload)

	case repository.KindPutawaySubmit:
		return s.putawaySubmit(ctx, userID, id, op.Payload)

	case repository.KindMovementSubmit:
		return s.movementSubmit(ctx, userID, id, op.Payload)

	case repository.KindProblemSubmit:
		return s.problemSubmit(ctx, userID, id, op.Payload)

	case repository.KindReturnSubmit:
		return s.returnSubmit(ctx, userID, id, op.Payload)

	default:
		return repository.Applied{}, ErrUnknownKind
	}
}

// isRejection отличает отказ по существу от временной неудачи.
//
// Граница здесь не косметическая: отклонённая операция снимается с очереди и уходит человеку
// на разбор, а временная — повторяется. Ошибись в сторону «временной», и очередь встанет
// навсегда на неисполнимой операции; ошибись в другую — работа кладовщика молча пропадёт.
// Поэтому список закрытый: всё неопознанное считается временным.
func isRejection(err error) bool {
	// Документ со списком отклонённых строк (ADHOC-40) — отказ по существу целиком, какими бы
	// ни были причины строк.
	var lines *repository.DocumentLinesError
	if errors.As(err, &lines) {
		return true
	}
	return errors.Is(err, repository.ErrBarcodeConflict) ||
		errors.Is(err, repository.ErrGoodNotFound) ||
		errors.Is(err, repository.ErrSessionNotFound) ||
		errors.Is(err, repository.ErrSessionClosed) ||
		errors.Is(err, ErrUnknownKind) ||
		errors.Is(err, ErrInvalidPayload) ||
		errors.Is(err, ErrInvalidOperationID) ||
		errors.Is(err, ErrEmptyGoodID) ||
		errors.Is(err, ErrEmptyBarcode) ||
		errors.Is(err, ErrInvalidQuantity) ||
		errors.Is(err, ErrInvalidDate) ||
		errors.Is(err, ErrInvalidSessionID) ||
		errors.Is(err, ErrEmptyWarehouse) ||
		errors.Is(err, ErrEmptyCell) ||
		// Приёмка (P4-09): документ уже оприходован, пуст, противоречив или ссылается на то,
		// чего нет. Ни одно из этого повтор не исправит.
		errors.Is(err, ErrInvalidReceiptID) ||
		errors.Is(err, ErrEmptyDocNumber) ||
		errors.Is(err, ErrDocNumberTooLong) ||
		errors.Is(err, ErrInvalidDocDate) ||
		errors.Is(err, ErrInvalidLoadUnitID) ||
		errors.Is(err, ErrInvalidLoadUnitKind) ||
		errors.Is(err, repository.ErrReceiptNotFound) ||
		errors.Is(err, repository.ErrReceiptPosted) ||
		errors.Is(err, repository.ErrEmptyReceipt) ||
		errors.Is(err, repository.ErrLoadUnitCellConflict) ||
		errors.Is(err, repository.ErrLoadUnitNotFound) ||
		errors.Is(err, repository.ErrNoDefaultCell) ||
		errors.Is(err, repository.ErrUnknownReference) ||
		// Марки ЧЗ приёмки (CZ-05): марка или короб уже приняты, код не по форме, GTIN марки —
		// не товар строки или незнаком, марок больше количества. Повтор этого не исправит — без
		// записи здесь очередь ТСД повторяла бы такую приёмку бесконечно.
		errors.Is(err, model.ErrCZMarkExists) ||
		errors.Is(err, model.ErrCZAggregateExists) ||
		errors.Is(err, model.ErrCZBadCode) ||
		errors.Is(err, model.ErrCZMarkGoodMismatch) ||
		errors.Is(err, model.ErrCZUnknownGTIN) ||
		errors.Is(err, model.ErrCZMarksExceedQty) ||
		// Марки ЧЗ движения, пометки проблемы и отгрузки возврата (CZ-06): нет марок у
		// маркируемого товара, их не столько, они не там или не той партии, у позиции возврата
		// названы не все или лишняя. Повтор этого не исправит.
		errors.Is(err, model.ErrCZMarksRequired) ||
		errors.Is(err, model.ErrCZMarksQtyMismatch) ||
		errors.Is(err, model.ErrCZMarkNotAtSource) ||
		errors.Is(err, model.ErrCZMarkBatchMismatch) ||
		errors.Is(err, model.ErrCZReturnMarksIncomplete) ||
		errors.Is(err, model.ErrCZReturnMarkForeign) ||
		// Размещение (P5-02): сеанс уже проведён, пуст, противоречит складу или просит больше,
		// чем лежит. Повтор этого не исправит — сеанс разбирает человек.
		errors.Is(err, ErrInvalidPutawayID) ||
		errors.Is(err, repository.ErrPutawayPosted) ||
		errors.Is(err, repository.ErrEmptyPutaway) ||
		errors.Is(err, repository.ErrPutawaySameCell) ||
		errors.Is(err, repository.ErrForeignCell) ||
		errors.Is(err, repository.ErrLoadUnitNotPlaced) ||
		errors.Is(err, repository.ErrLoadUnitNested) ||
		errors.Is(err, repository.ErrLooseStockShort) ||
		errors.Is(err, repository.ErrInsufficientStock) ||
		// Задание сеанса (P5-02-1): нет, выполнено, не того склада или сеанс просит лишнего.
		errors.Is(err, ErrInvalidTaskID) ||
		errors.Is(err, repository.ErrTaskNotFound) ||
		errors.Is(err, repository.ErrTaskDone) ||
		errors.Is(err, repository.ErrTaskMismatch) ||
		errors.Is(err, repository.ErrNotInTask) ||
		errors.Is(err, repository.ErrExceedsTask) ||
		// Движение (P6-03): документ уже проведён, пуст, противоречив или просит больше, чем
		// лежит в источнике. Повтор этого не исправит — документ разбирает человек.
		errors.Is(err, ErrInvalidMovementID) ||
		errors.Is(err, repository.ErrMovementPosted) ||
		errors.Is(err, repository.ErrEmptyMovement) ||
		errors.Is(err, repository.ErrUnknownMovementKind) ||
		errors.Is(err, repository.ErrReceivingCell) ||
		errors.Is(err, repository.ErrWarehouseMismatch) ||
		errors.Is(err, repository.ErrEmptyMovementLine) ||
		errors.Is(err, repository.ErrSameCell) ||
		errors.Is(err, repository.ErrSamePlace) ||
		errors.Is(err, repository.ErrGoodsShort) ||
		errors.Is(err, repository.ErrMovementQty) ||
		// Проблемы склада (P6-07-1): уже зафиксирована, пуста, причина или склад не те, товар
		// уже на складе назначения или склад системный (P6-07-3). Повтор этого не исправит.
		errors.Is(err, ErrInvalidProblemID) ||
		errors.Is(err, ErrProblemCommentRequired) ||
		errors.Is(err, repository.ErrProblemPosted) ||
		errors.Is(err, repository.ErrEmptyProblem) ||
		errors.Is(err, repository.ErrUnknownReason) ||
		errors.Is(err, repository.ErrUnknownInternalWarehouse) ||
		errors.Is(err, repository.ErrSameInternalWarehouse) ||
		errors.Is(err, repository.ErrSystemInternalWarehouse) ||
		// Отгрузка возврата (ADHOC-31): сеанс уже проведён, пуст, позиция не из задания или уже
		// отгружена, товара позиции нет на складе возврата.
		errors.Is(err, ErrInvalidShipmentID) ||
		errors.Is(err, repository.ErrShipmentPosted) ||
		errors.Is(err, repository.ErrEmptyShipment) ||
		errors.Is(err, repository.ErrProblemGoodsMissing)
}

// rejected собирает результат-отказ с причиной, читаемой человеком на экране разбора.
func rejected(id string, err error) OperationResult {
	return OperationResult{OperationID: id, Status: StatusRejected, Error: err.Error()}
}
