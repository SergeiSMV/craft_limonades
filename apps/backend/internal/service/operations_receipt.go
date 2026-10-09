package service

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/shopspring/decimal"

	"craftwms/internal/model"
	"craftwms/internal/repository"
)

// ErrInvalidReceiptID — идентификатор документа приёмки не UUID.
//
// Отдельно от ErrEmptyReceiptID: у прямой ручки пустой id — это пропущенное поле, а в операции
// очереди документ адресуется своим id офлайн, и id не по форме означает испорченную операцию.
var ErrInvalidReceiptID = errors.New("receipt id must be a UUID")

// receiptSubmitPayload — тело операции receipt_submit, как его собирает устройство.
type receiptSubmitPayload struct {
	ReceiptID   string `json:"receipt_id"`
	WarehouseID string `json:"warehouse_id"`
	SupplierID  string `json:"supplier_id"`
	DocNumber   string `json:"doc_number"` // накладная поставщика (ADHOC-23)
	DocDate     string `json:"doc_date"`   // DD-MM-YYYY
	LoadUnits   []struct {
		ID   string `json:"id"`
		Kind string `json:"kind"`
	} `json:"load_units"`
	Lines []struct {
		GoodID         string          `json:"good_id"`
		ProductionDate string          `json:"production_date"`
		CellID         string          `json:"cell_id"`
		LoadUnitID     string          `json:"load_unit_id"`
		Qty            decimal.Decimal `json:"qty"`
	} `json:"lines"`
}

// receiptSubmit разбирает и проверяет приёмку из очереди устройства (P4-09).
//
// Всё, что можно проверить без базы, проверяется здесь: идентификаторы по форме, количества,
// даты. Ошибка формы — отказ по существу (повтор её не исправит), и лучше получить его до
// открытия транзакции, чем нарушением типа на середине вставки.
//
// Автор — из токена, а не из тела: иначе устройство могло бы записать приёмку на другого.
func (s *OperationsService) receiptSubmit(ctx context.Context, userID, id string, raw json.RawMessage) (repository.Applied, error) {
	var p receiptSubmitPayload
	if err := json.Unmarshal(raw, &p); err != nil {
		return repository.Applied{}, ErrInvalidPayload
	}
	in := repository.ReceiptSubmitInput{
		ReceiptID:   strings.TrimSpace(p.ReceiptID),
		WarehouseID: strings.TrimSpace(p.WarehouseID),
		SupplierID:  strings.TrimSpace(p.SupplierID),
		CreatedBy:   userID,
	}
	if !isUUID(in.ReceiptID) {
		return repository.Applied{}, ErrInvalidReceiptID
	}
	if in.WarehouseID == "" {
		return repository.Applied{}, ErrEmptyWarehouse
	}
	if !isUUID(in.WarehouseID) || !isOptionalUUID(in.SupplierID) {
		return repository.Applied{}, ErrInvalidPayload
	}
	// Накладная обязательна (ADHOC-23): приёмку без неё сервер не проводит — нечего занести
	// в 1С основанием. Отказ по существу: повтор того же тела ничего не исправит.
	doc, err := parseSupplierDoc(p.DocNumber, p.DocDate, time.Now())
	if err != nil {
		return repository.Applied{}, err
	}
	in.Doc = doc
	// Пустую приёмку отсекаем до базы: оприходовать нечего, а открытый ради отказа документ
	// откатился бы вместе с транзакцией и всё равно ничего не дал.
	if len(p.Lines) == 0 {
		return repository.Applied{}, repository.ErrEmptyReceipt
	}

	for _, lu := range p.LoadUnits {
		luID := strings.TrimSpace(lu.ID)
		if !isUUID(luID) {
			return repository.Applied{}, ErrInvalidLoadUnitID
		}
		kind := strings.TrimSpace(lu.Kind)
		if kind == "" {
			kind = model.LoadUnitBox // тот же умолчательный вид, что у прямой ручки
		}
		if kind != model.LoadUnitBox && kind != model.LoadUnitPallet {
			return repository.Applied{}, ErrInvalidLoadUnitKind
		}
		in.LoadUnits = append(in.LoadUnits, repository.LoadUnitInput{ID: luID, Kind: kind})
	}

	for _, ln := range p.Lines {
		goodID := strings.TrimSpace(ln.GoodID)
		cellID := strings.TrimSpace(ln.CellID)
		luID := strings.TrimSpace(ln.LoadUnitID)
		if goodID == "" {
			return repository.Applied{}, ErrEmptyGoodID
		}
		if !isUUID(goodID) || !isOptionalUUID(cellID) {
			return repository.Applied{}, ErrInvalidPayload
		}
		if !isOptionalUUID(luID) {
			return repository.Applied{}, ErrInvalidLoadUnitID
		}
		if !ln.Qty.IsPositive() {
			return repository.Applied{}, ErrInvalidQuantity
		}
		iso, err := parseEntryDate(ln.ProductionDate)
		if err != nil {
			return repository.Applied{}, err
		}
		in.Lines = append(in.Lines, model.ReceiptLineInput{
			GoodID: goodID, ProductionDate: iso, CellID: cellID, LoadUnitID: luID, Qty: ln.Qty,
		})
	}
	return s.repo.ReceiptSubmit(ctx, id, in)
}

// isUUID — строка по форме UUID.
func isUUID(s string) bool {
	_, err := uuid.Parse(s)
	return err == nil
}

// isOptionalUUID — пусто или UUID: необязательная ссылка.
func isOptionalUUID(s string) bool {
	return s == "" || isUUID(s)
}
