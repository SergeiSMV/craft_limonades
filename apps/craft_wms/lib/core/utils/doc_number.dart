import '../gen/strings.g.dart';

/// Вид операции или документа — у каждого свой счётчик номеров на сервере (ADHOC-55).
enum DocKind {
  receipt,
  putaway,
  move,
  replenish,
  stockEntry,
  returnShipment,
  task,
  stocktake,
  problem,
  // Документы для 1С — свой счётчик у формы.
  receiptDoc,
  movementDoc,
  stockEntryDoc,
  stocktakeDoc,
}

/// Номер для людей: префикс вида и номер сервера с ведущими нулями — «ПБ-000009».
///
/// Что: единый вид номера на ТСД и в портале.
/// Зачем: ни операции, ни документа без номера; номера разных видов совпадают, а префикс
/// различает их и в разговоре, и в поиске.
/// Как: сервер хранит только число (счётчик вида), префикс и ширину добавляет показ —
/// поэтому меняются они здесь, без миграции. Документ 1С собирает сервер — у него та же
/// таблица префиксов (`model.DocPrefix*`), два места меняются вместе.
String docNumber(DocKind kind, int number) {
  final p = t.docNumber;
  final prefix = switch (kind) {
    DocKind.receipt => p.prefixReceipt,
    DocKind.putaway => p.prefixPutaway,
    DocKind.move => p.prefixMove,
    DocKind.replenish => p.prefixReplenish,
    DocKind.stockEntry => p.prefixStockEntry,
    DocKind.returnShipment => p.prefixReturnShipment,
    DocKind.task => p.prefixTask,
    DocKind.stocktake => p.prefixStocktake,
    DocKind.problem => p.prefixProblem,
    DocKind.receiptDoc => p.prefixReceiptDoc,
    DocKind.movementDoc => p.prefixMovementDoc,
    DocKind.stockEntryDoc => p.prefixStockEntryDoc,
    DocKind.stocktakeDoc => p.prefixStocktakeDoc,
  };
  return '$prefix-${number.toString().padLeft(_width, '0')}';
}

/// Вид номера операции по её коду с сервера: `receipt`, `putaway`, `move`, `replenish`,
/// `stocktake`; незнакомый — `null`.
DocKind? operationDocKind(String operation) => switch (operation) {
  'receipt' => DocKind.receipt,
  'putaway' => DocKind.putaway,
  'move' => DocKind.move,
  'replenish' => DocKind.replenish,
  'stocktake' => DocKind.stocktake,
  'stock_entry' => DocKind.stockEntry,
  _ => null,
};

/// Короткие формы номеров из текста для поиска: «ПМ-000001» → «ПМ-1», «ПМ1». Человек
/// набирает номер так, как его называет, — без ведущих нулей.
Iterable<String> shortDocNumbers(String text) sync* {
  for (final m in _numberPattern.allMatches(text)) {
    final n = int.parse(m.group(2)!);
    yield '${m.group(1)}-$n';
    yield '${m.group(1)}$n';
  }
}

final _numberPattern = RegExp('([А-ЯЁ]{2})-(\\d{$_width})');

/// Ширина числовой части номера.
const _width = 6;
