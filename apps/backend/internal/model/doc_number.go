package model

import "fmt"

// Префиксы номеров (ADHOC-55): у каждой операции и каждого документа для 1С свой счётчик, в
// базе — число, человек видит префикс и шесть цифр. Те же префиксы — у `docNumber` на ТСД и в
// портале (`core/utils/doc_number.dart`): номер в документе 1С и на экране один и тот же, два
// места меняются вместе.
const (
	DocPrefixReceipt        = "ПР" // приёмка
	DocPrefixPutaway        = "РЗ" // размещение (сеанс по заданию)
	DocPrefixMove           = "ПМ" // перемещение
	DocPrefixReplenish      = "ПП" // пополнение
	DocPrefixStockEntry     = "ВО" // ввод остатков
	DocPrefixReturnShipment = "ВП" // отгрузка возврата поставщику
	DocPrefixTask           = "ЗД" // задание
	DocPrefixStocktake      = "ИН" // пересчёт
	DocPrefixProblem        = "ПБ" // проблема склада
	DocPrefixPicking        = "СБ" // сборка заказа по реестру 1С (P9-02)

	// Документы для 1С — свой счётчик у формы.
	DocPrefixReceiptDoc    = "ДП" // «Поступление»
	DocPrefixMovementDoc   = "ДД" // «Движение»
	DocPrefixStockEntryDoc = "ДВ" // «Ввод остатков»
	DocPrefixStocktakeDoc  = "ДИ" // «Инвентаризация»
)

// DocNumber — номер для человека: префикс вида и шесть цифр, «ПМ-000001».
func DocNumber(prefix string, n int64) string {
	return fmt.Sprintf("%s-%06d", prefix, n)
}

// ReportDocPrefix — префикс номера документа 1С по его форме; незнакомая форма — пусто.
func ReportDocPrefix(kind string) string {
	switch kind {
	case ReportKindReceipt:
		return DocPrefixReceiptDoc
	case ReportKindMovement:
		return DocPrefixMovementDoc
	case ReportKindStockEntry:
		return DocPrefixStockEntryDoc
	case ReportKindStocktake:
		return DocPrefixStocktakeDoc
	default:
		return ""
	}
}

// OperationPrefix — префикс номера операции-источника документа «Движение» по операции
// снимка; у остальных форм операция одна и префикс известен по форме.
func OperationPrefix(operation string) string {
	switch operation {
	case MovementOperationPutaway:
		return DocPrefixPutaway
	case MovementOperationMove:
		return DocPrefixMove
	case MovementOperationReplenish:
		return DocPrefixReplenish
	default:
		return ""
	}
}
