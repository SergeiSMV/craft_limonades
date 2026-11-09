package service

import (
	"context"
	"fmt"
	"io"
	"sort"
	"time"

	"craftwms/internal/importer"
	"craftwms/internal/model"
)

// registryGoodsRepo — узкий интерфейс справочника для сопоставления реестра: товары по кодам.
type registryGoodsRepo interface {
	ByCodes(ctx context.Context, codes []string) (map[string]model.RegistryGood, error)
}

// PickingRegistryService — разбор «Реестра» 1С на сборку и сопоставление его строк с
// номенклатурой (P9-01). Загрузка с предпросмотром — P8-02, задания сборки — P9-02…P9-03.
type PickingRegistryService struct {
	goods registryGoodsRepo
}

// NewPickingRegistryService собирает сервис разбора реестра.
func NewPickingRegistryService(goods registryGoodsRepo) *PickingRegistryService {
	return &PickingRegistryService{goods: goods}
}

// RegistryLine — строка реестра с товаром справочника. Good == nil — кода нет в справочнике.
type RegistryLine struct {
	importer.RegistryRow
	Good *model.RegistryGood
}

// RegistryOrder — документ сборки «накладная + заказ» со строками в порядке файла.
// HasUnknown — есть строки, чей код не найден в справочнике: такой заказ загружается с пометкой
// «есть нераспознанные позиции», а сборка по нему не начинается до обновления номенклатуры и
// повторной загрузки реестра (docs/picking.md, «Сопоставление»).
type RegistryOrder struct {
	InvoiceNumber string
	OrderNumber   string
	InvoiceDate   time.Time
	OrderDate     *time.Time
	Direction     string
	Client        string
	Address       string
	Lines         []RegistryLine
	HasUnknown    bool
}

// RegistryParsed — разобранный реестр: дата сборки, заказы, нераспознанные коды и отклонённые
// строки файла.
type RegistryParsed struct {
	Date         time.Time
	Orders       []RegistryOrder
	UnknownCodes []string // коды без товара в справочнике, по возрастанию, без повторов
	Errors       []importer.RowError
}

// Parse разбирает файл реестра и сопоставляет строки с номенклатурой по коду.
//
// Что: файл → заказы со строками и найденными товарами. Зачем: на этом строятся предпросмотр
// загрузки (P8-02) и документы сборки (P9-02). Как: importer.ParseRegistry даёт строки с кодом в
// формате справочника, справочник читается одним запросом на все коды файла; строки
// группируются в заказы в порядке первого появления. Шапку заказа (клиент, адрес, направление,
// даты) даёт его первая строка: 1С повторяет её в каждой строке документа. Нераспознанный код не
// отклоняет строку — она остаётся в заказе без товара, чтобы оператор видел её в предпросмотре.
func (s *PickingRegistryService) Parse(ctx context.Context, r io.Reader) (*RegistryParsed, error) {
	parsed, err := importer.ParseRegistry(r)
	if err != nil {
		// Файл не принят целиком — ошибка ввода (ErrRegistryFile), хендлер отвечает 422.
		return nil, fmt.Errorf("%w: %w", ErrRegistryFile, err)
	}

	codes := make([]string, 0, len(parsed.Rows))
	seen := map[string]bool{}
	for _, row := range parsed.Rows {
		if !seen[row.GoodCode] {
			seen[row.GoodCode] = true
			codes = append(codes, row.GoodCode)
		}
	}
	goods, err := s.goods.ByCodes(ctx, codes)
	if err != nil {
		return nil, fmt.Errorf("сопоставление с номенклатурой: %w", err)
	}

	out := &RegistryParsed{Date: parsed.Date, Errors: parsed.Errors}
	orderIdx := map[string]int{} // номер заказа → индекс в out.Orders
	unknown := map[string]bool{}
	for _, row := range parsed.Rows {
		i, ok := orderIdx[row.OrderNumber]
		if !ok {
			i = len(out.Orders)
			orderIdx[row.OrderNumber] = i
			out.Orders = append(out.Orders, RegistryOrder{
				InvoiceNumber: row.InvoiceNumber,
				OrderNumber:   row.OrderNumber,
				InvoiceDate:   row.InvoiceDate,
				OrderDate:     row.OrderDate,
				Direction:     row.Direction,
				Client:        row.Client,
				Address:       row.Address,
			})
		}
		line := RegistryLine{RegistryRow: row}
		if g, found := goods[row.GoodCode]; found {
			line.Good = &g
		} else {
			out.Orders[i].HasUnknown = true
			unknown[row.GoodCode] = true
		}
		out.Orders[i].Lines = append(out.Orders[i].Lines, line)
	}
	for code := range unknown {
		out.UnknownCodes = append(out.UnknownCodes, code)
	}
	sort.Strings(out.UnknownCodes)
	return out, nil
}
