package service

import (
	"context"
	"errors"
	"strings"

	"craftwms/internal/model"
)

// barcodeRepo - зависимость сервиса от хранилища ШК (интерфейс ради тестируемости).
type barcodeRepo interface {
	GetGoodByBarcode(ctx context.Context, code string) (model.Good, error)
	ListByGood(ctx context.Context, goodID string) ([]model.Barcode, error)
	List(ctx context.Context, limit, offset int) ([]model.BarcodeLink, int, error)
	Bind(ctx context.Context, goodID, barcode, symbology string) error
	Unbind(ctx context.Context, barcode string) error
	InternalByGood(ctx context.Context, goodID string) (string, error)
	CreateInternal(ctx context.Context, goodID string) (string, error)
	CZStockOfBarcode(ctx context.Context, barcode string) (int, error)
	Regrade(ctx context.Context, in model.RegradeInput) (model.RegradeResult, error)
}

// BarcodeService - резолв товара по ШК и привязка ШК к товару (ввод остатков P-FastStart).
// Валидирует ввод; доменные ошибки хранилища (ErrNotFound/ErrBarcodeConflict/ErrGoodNotFound)
// проходят как есть - хендлер маппит их в HTTP-коды.
type BarcodeService struct {
	repo barcodeRepo
}

// NewBarcodeService собирает сервис из репозитория ШК.
func NewBarcodeService(repo barcodeRepo) *BarcodeService {
	return &BarcodeService{repo: repo}
}

// ResolveGood - товар по ШК; нет привязки → model.ErrNotFound.
func (s *BarcodeService) ResolveGood(ctx context.Context, code string) (model.Good, error) {
	code = strings.TrimSpace(code)
	if code == "" {
		return model.Good{}, model.ErrEmptyBarcode
	}
	return s.repo.GetGoodByBarcode(ctx, code)
}

// ListByGood - все ШК товара (секция «Штрихкоды» в карточке). Пустой good_id отклоняется.
func (s *BarcodeService) ListByGood(ctx context.Context, goodID string) ([]model.Barcode, error) {
	goodID = strings.TrimSpace(goodID)
	if goodID == "" {
		return nil, model.ErrEmptyGoodID
	}
	return s.repo.ListByGood(ctx, goodID)
}

// List - страница всех привязок ШК: справочник целиком для кэша устройства (P2-02).
// Границы limit/offset те же, что у остальных справочников (clampPaging), чтобы клиент
// листал одинаково везде.
func (s *BarcodeService) List(ctx context.Context, limit, offset int) (Page[model.BarcodeLink], error) {
	limit, offset = clampPaging(limit, offset)
	items, total, err := s.repo.List(ctx, limit, offset)
	if err != nil {
		return Page[model.BarcodeLink]{}, err
	}
	return Page[model.BarcodeLink]{Items: items, Total: total, Limit: limit, Offset: offset}, nil
}

// Bind - привязать ШК к товару (аддитивно, идемпотентно). Пустые good_id/barcode отклоняются.
func (s *BarcodeService) Bind(ctx context.Context, goodID, barcode, symbology string) error {
	goodID = strings.TrimSpace(goodID)
	barcode = strings.TrimSpace(barcode)
	symbology = strings.TrimSpace(symbology)
	if goodID == "" {
		return model.ErrEmptyGoodID
	}
	if barcode == "" {
		return model.ErrEmptyBarcode
	}
	return s.repo.Bind(ctx, goodID, barcode, symbology)
}

// GenerateInternal выдаёт товару внутренний ШК и возвращает его.
//
// Что: EAN-13 с префиксом 20-29 и контрольной цифрой для товара, у которого своего ШК нет.
// Зачем: без штрихкода товар выпадает из всей работы склада - его не принять сканом, не найти
// в ячейке, не собрать в заказ. Код печатается на ярлыке (P4-08) и наклеивается.
//
// **Идемпотентно по товару.** Уже выданный внутренний ШК возвращается как есть, второй не
// заводится. Иначе повторное нажатие (связь мигнула, кладовщик не увидел ответа) дало бы товару
// два кода, из которых на упаковке наклеен один, - и второй жил бы в справочнике мусором.
// Перепечать испорченной этикетки идёт этим же вызовом и даёт тот же код.
//
// Товар при этом может иметь и внешние ШК: привязка аддитивна (1→N), и внутренний код просто
// встаёт рядом. Это не противоречие - у коробки может быть и свой штрихкод, и наш.
// Второе возвращаемое значение - создан ли код сейчас. По нему экран отличает «выдали новый»
// от «он уже был»: во втором случае человеку стоит сказать, что он переклеивает существующий,
// а не заводит ещё один.
func (s *BarcodeService) GenerateInternal(ctx context.Context, goodID string) (string, bool, error) {
	goodID = strings.TrimSpace(goodID)
	if goodID == "" {
		return "", false, model.ErrEmptyGoodID
	}
	code, err := s.repo.InternalByGood(ctx, goodID)
	switch {
	case err == nil:
		return code, false, nil
	case errors.Is(err, model.ErrNotFound):
		created, err := s.repo.CreateInternal(ctx, goodID)
		if err != nil {
			return "", false, err
		}
		return created, true, nil
	default:
		return "", false, err
	}
}

// Unbind - отвязать ШК (коррекция ошибочной привязки, P-FS-12). Идемпотентно на уровне репозитория
// (нет привязки → не ошибка). Пустой barcode отклоняется.
func (s *BarcodeService) Unbind(ctx context.Context, barcode string) error {
	barcode = strings.TrimSpace(barcode)
	if barcode == "" {
		return model.ErrEmptyBarcode
	}
	return s.repo.Unbind(ctx, barcode)
}

// CZStock - сколько марок ЧЗ с этим ШК на складе (ADHOC-53): ТСД спрашивает перед отвязкой ШК
// маркируемого товара и, если марки есть, предлагает перепривязку.
func (s *BarcodeService) CZStock(ctx context.Context, barcode string) (int, error) {
	barcode = strings.TrimSpace(barcode)
	if barcode == "" {
		return 0, model.ErrEmptyBarcode
	}
	return s.repo.CZStockOfBarcode(ctx, barcode)
}

// Regrade - перепривязать ШК к другому товару с пересортом марок ЧЗ со склада (ADHOC-53).
func (s *BarcodeService) Regrade(ctx context.Context, in model.RegradeInput) (model.RegradeResult, error) {
	in.Barcode = strings.TrimSpace(in.Barcode)
	in.GoodID = strings.TrimSpace(in.GoodID)
	if in.Barcode == "" {
		return model.RegradeResult{}, model.ErrEmptyBarcode
	}
	if !isUUID(in.GoodID) {
		return model.RegradeResult{}, model.ErrEmptyGoodID
	}
	return s.repo.Regrade(ctx, in)
}
