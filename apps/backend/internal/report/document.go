package report

import (
	"fmt"

	"craftwms/internal/model"
)

// ErrUnknownKind — для документа нет шаблона: значение `kind` в БД не совпало ни с одной формой.
var ErrUnknownKind = fmt.Errorf("неизвестная форма документа")

// BuildDocumentXLSX собирает .xlsx документа по его форме.
//
// Здесь единственная развилка «форма → шаблон» во всём бэкенде: новая форма (P4 «Поступление»,
// P5-04 «Движение») добавляется одной веткой, а вызывающий код — сервис документов и портал —
// не меняется вовсе. Данные берутся из снимка, поэтому шаблон видит документ таким, каким его
// завершили, и не зависит от текущего состояния справочников.
func BuildDocumentXLSX(doc model.ReportDocument) ([]byte, error) {
	switch doc.Kind {
	case model.ReportKindStockEntry:
		return BuildStockEntryXLSX(stockEntryReportFrom(doc.Snapshot))
	case model.ReportKindReceipt:
		return BuildReceiptXLSX(doc.Snapshot)
	case model.ReportKindMovement:
		return BuildMovementXLSX(doc.Snapshot)
	case model.ReportKindStocktake:
		return BuildStocktakeXLSX(doc.Snapshot)
	default:
		return nil, fmt.Errorf("%w: %q", ErrUnknownKind, doc.Kind)
	}
}

// DocumentFilename — имя файла для скачивания: форма, склад и дата документа.
// Латиницей и без пробелов: имя уезжает в заголовок Content-Disposition и в файловую систему
// оператора, а кириллица там требует кодирования и по-разному переживает браузеры.
func DocumentFilename(doc model.ReportDocument) string {
	prefix := "document"
	switch doc.Kind {
	case model.ReportKindStockEntry:
		prefix = "vvod-ostatkov"
	case model.ReportKindReceipt:
		prefix = "postuplenie"
	case model.ReportKindMovement:
		prefix = "dvizhenie"
	case model.ReportKindStocktake:
		prefix = "inventarizaciya"
	}
	return fmt.Sprintf("%s-%s-%s.xlsx", prefix, doc.Snapshot.WarehouseCode, doc.CreatedAt.Format("20060102"))
}

// stockEntryReportFrom переводит снимок в модель шаблона «ввод остатков».
func stockEntryReportFrom(s model.ReportSnapshot) model.StockEntryReport {
	rep := model.StockEntryReport{
		WarehouseCode: s.WarehouseCode,
		WarehouseName: s.WarehouseName,
		CreatedAt:     s.CreatedAt,
		Rows:          make([]model.StockEntryReportRow, 0, len(s.Rows)),
	}
	for _, r := range s.Rows {
		// Поле в поле, а не приведение типа: у строки снимка есть поля других форм
		// (ячейка-отправитель «Движения»), которых у ввода остатков нет.
		rep.Rows = append(rep.Rows, model.StockEntryReportRow{
			CellAddress: r.CellAddress, GoodCode: r.GoodCode, GoodName: r.GoodName,
			ProductionDate: r.ProductionDate, Qty: r.Qty, Mark: r.Mark,
		})
	}
	return rep
}
