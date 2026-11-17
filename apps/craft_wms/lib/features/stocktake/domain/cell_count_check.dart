/// Ячейка склада сейчас на подсчёте пересчёта (ADHOC-48): кто считает и какой пересчёт.
class CellUnderCount {
  const CellUnderCount({
    required this.stocktakeNumber,
    required this.address,
    required this.countedBy,
    required this.startedAt,
  });

  factory CellUnderCount.fromJson(Map<String, dynamic> json) => CellUnderCount(
    stocktakeNumber: (json['stocktake_number'] as num).toInt(),
    address: json['address'] as String,
    countedBy: json['counted_by'] as String? ?? '',
    startedAt: json['started_at'] as String? ?? '',
  );

  final int stocktakeNumber;
  final String address;
  final String countedBy;

  /// Начало подсчёта (RFC3339): отличает один подсчёт ячейки от следующего.
  final String startedAt;
}

/// Проверка ячейки перед движением через неё (ADHOC-48).
///
/// Что: идёт ли в ячейке подсчёт пересчёта - спрашивается сервер в момент скана.
/// Зачем: движение через ячейку на подсчёте сбивает его (мягкая блокировка P10-02), и
/// кладовщик должен узнать об этом до движения, а не считающий - после.
/// Как: только со связью и с коротким ожиданием; без связи или при ошибке - `null`, как
/// будто подсчёта нет: сервер движение всё равно примет и пометит подсчёт сбитым.
abstract interface class CellCountCheck {
  /// Подсчёт в ячейке [cellId]; `null` - не идёт или узнать не удалось. Подсчёт, движение
  /// через который кладовщик уже подтвердил, второй раз не возвращается.
  Future<CellUnderCount?> counting(String cellId);

  /// Кладовщик подтвердил движение через ячейку на подсчёте - больше о нём не спрашивать.
  void confirmed(String cellId, CellUnderCount count);
}
