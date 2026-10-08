/// Сущности просмотра содержимого ячеек и коробов (P5-05).
///
/// Слой `domain` фичи: ни Flutter, ни сети, ни базы — экраны и кубиты зависят только от него
/// (dev.md §2). Даты партий — в транспортном виде DD-MM-YYYY, как их несут сервер и операции
/// очереди; в привычный вид их переводит экран.
library;

/// Товар одной партии с количеством: строка содержимого короба или россыпи в ячейке.
class ContentLine {
  const ContentLine({
    required this.goodId,
    this.goodName,
    this.goodCode,
    this.uom,
    required this.productionDate,
    required this.qty,
    this.pending = false,
  });

  final String goodId;

  /// Наименование; `null` — товара нет в справочнике терминала (заведён после загрузки).
  final String? goodName;
  final String? goodCode;
  final String? uom;

  /// Дата партии, DD-MM-YYYY.
  final String productionDate;
  final double qty;

  /// Строку изменила своя неотправленная операция — показывается с пометкой.
  final bool pending;

  /// Та же ли это партия товара — по ней сводятся строки снимка и операций очереди.
  bool sameBatch(ContentLine other) =>
      goodId == other.goodId && productionDate == other.productionDate;

  ContentLine copyWith({
    String? goodName,
    String? goodCode,
    String? uom,
    double? qty,
    bool? pending,
  }) => ContentLine(
    goodId: goodId,
    goodName: goodName ?? this.goodName,
    goodCode: goodCode ?? this.goodCode,
    uom: uom ?? this.uom,
    productionDate: productionDate,
    qty: qty ?? this.qty,
    pending: pending ?? this.pending,
  );
}

/// Короб так, как его видит кладовщик: где лежит и что внутри.
class LoadUnitView {
  const LoadUnitView({
    required this.id,
    this.kind = 'box',
    this.cellId,
    this.cellAddress,
    this.createdAt,
    required this.live,
    this.lines = const [],
    this.pending = false,
  });

  final String id;
  final String kind;

  /// Ячейка, где короб лежит; `null` — не размещён.
  final String? cellId;
  final String? cellAddress;
  final DateTime? createdAt;

  /// Живой — размещён и не пуст. Неживой короб показывается, но с объяснением.
  final bool live;
  final List<ContentLine> lines;

  /// Короб создан или перенесён своей неотправленной операцией.
  final bool pending;

  LoadUnitView copyWith({
    String? cellId,
    String? cellAddress,
    bool? live,
    List<ContentLine>? lines,
    bool? pending,
  }) => LoadUnitView(
    id: id,
    kind: kind,
    cellId: cellId ?? this.cellId,
    cellAddress: cellAddress ?? this.cellAddress,
    createdAt: createdAt,
    live: live ?? this.live,
    lines: lines ?? this.lines,
    pending: pending ?? this.pending,
  );
}

/// Что лежит в ячейке: живые короба и россыпь.
class CellView {
  const CellView({
    required this.cellId,
    required this.address,
    this.loadUnits = const [],
    this.loose = const [],
  });

  final String cellId;
  final String address;
  final List<LoadUnitView> loadUnits;
  final List<ContentLine> loose;

  bool get isEmpty => loadUnits.isEmpty && loose.isEmpty;
}

/// Ячейка, найденная по отсканированному адресу.
class CellRef {
  const CellRef({required this.id, required this.address});

  final String id;
  final String address;
}

/// Откуда данные на экране.
sealed class DataFreshness {
  const DataFreshness();
}

/// Ответ сервера — данные точные на сейчас.
final class FreshFromServer extends DataFreshness {
  const FreshFromServer();
}

/// Связи нет — данные из снимка на терминале.
final class FromSnapshot extends DataFreshness {
  const FromSnapshot(this.asOf);

  /// Момент, на который согласован снимок; `null` — снимка ещё не было, на экране только
  /// свои неотправленные операции.
  final DateTime? asOf;
}

/// Найденное вместе с тем, откуда оно взято. [value] `null` — не найдено: на сервере
/// (со связью) или в снимке (без связи — короб мог появиться после загрузки).
class Viewed<T> {
  const Viewed(this.value, this.freshness);

  final T? value;
  final DataFreshness freshness;
}
