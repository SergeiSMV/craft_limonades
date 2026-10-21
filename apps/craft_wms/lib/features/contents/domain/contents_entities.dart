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
    this.internalWarehouseId,
    this.internalWarehouseName,
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

  /// Внутренний склад строки (P6-07-2); `null` — «Основной». У строки короба — склад короба.
  final String? internalWarehouseId;

  /// Как склад показывается человеку («Брак», «Изолятор»); `null` — «Основной» или склад,
  /// которого нет в справочнике терминала.
  final String? internalWarehouseName;

  /// Та же ли это партия товара того же склада — по ней сводятся строки снимка и операций
  /// очереди. Брак и основной товар одной партии — разные строки.
  bool sameBatch(ContentLine other) =>
      goodId == other.goodId &&
      productionDate == other.productionDate &&
      internalWarehouseId == other.internalWarehouseId;

  ContentLine copyWith({
    String? goodName,
    String? goodCode,
    String? uom,
    double? qty,
    bool? pending,
    String? internalWarehouseName,
  }) => ContentLine(
    goodId: goodId,
    goodName: goodName ?? this.goodName,
    goodCode: goodCode ?? this.goodCode,
    uom: uom ?? this.uom,
    productionDate: productionDate,
    qty: qty ?? this.qty,
    pending: pending ?? this.pending,
    internalWarehouseId: internalWarehouseId,
    internalWarehouseName: internalWarehouseName ?? this.internalWarehouseName,
  );

  /// Та же строка на другом складе (P6-07-2): пометка браком переводит её целиком.
  ContentLine onWarehouse(String? id) => ContentLine(
    goodId: goodId,
    goodName: goodName,
    goodCode: goodCode,
    uom: uom,
    productionDate: productionDate,
    qty: qty,
    pending: pending,
    internalWarehouseId: id,
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
    this.internalWarehouseId,
    this.internalWarehouseName,
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

  /// Внутренний склад короба целиком (P6-07-2); `null` — «Основной».
  final String? internalWarehouseId;

  /// Как склад показывается человеку; `null` — «Основной».
  final String? internalWarehouseName;

  LoadUnitView copyWith({
    String? cellId,
    String? cellAddress,
    bool? live,
    List<ContentLine>? lines,
    bool? pending,
    String? internalWarehouseName,
  }) => LoadUnitView(
    id: id,
    kind: kind,
    cellId: cellId ?? this.cellId,
    cellAddress: cellAddress ?? this.cellAddress,
    createdAt: createdAt,
    live: live ?? this.live,
    lines: lines ?? this.lines,
    pending: pending ?? this.pending,
    internalWarehouseId: internalWarehouseId,
    internalWarehouseName: internalWarehouseName ?? this.internalWarehouseName,
  );

  /// Тот же короб на другом складе — со строками этого склада (P6-07-2).
  LoadUnitView onWarehouse(String? id) => LoadUnitView(
    id: this.id,
    kind: kind,
    cellId: cellId,
    cellAddress: cellAddress,
    createdAt: createdAt,
    live: live,
    lines: [for (final l in lines) l.onWarehouse(id)],
    pending: pending,
    internalWarehouseId: id,
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

/// Данные из снимка на терминале: сервер сейчас не дал ответа.
final class FromSnapshot extends DataFreshness {
  const FromSnapshot(this.asOf, {this.offline = true});

  /// Момент, на который согласован снимок; `null` — снимка ещё не было, на экране только
  /// свои неотправленные операции.
  final DateTime? asOf;

  /// Причина — обрыв связи. `false` — связь есть, но сервер ответил ошибкой (сбой, старая
  /// версия без нужной ручки): писать «нет связи» тогда — неправда (ADHOC-22).
  final bool offline;
}

/// Найденное вместе с тем, откуда оно взято. [value] `null` — не найдено: на сервере
/// (со связью) или в снимке (без связи — короб мог появиться после загрузки).
class Viewed<T> {
  const Viewed(this.value, this.freshness);

  final T? value;
  final DataFreshness freshness;
}

/// Приёмка, которая завела короб: кто принял, от кого, когда оприходована (P5-05-1).
class LoadUnitReceiptInfo {
  const LoadUnitReceiptInfo({
    this.docNumber,
    this.docDate,
    required this.receivedBy,
    this.supplier,
    this.postedAt,
  });

  /// Документ поставщика (ADHOC-23): номер и дата DD-MM-YYYY; `null` — сервер до ADHOC-23.
  final String? docNumber;
  final String? docDate;

  final String receivedBy;

  /// `null` — приёмка без поставщика.
  final String? supplier;

  /// `null` — документ ещё не оприходован.
  final DateTime? postedAt;
}

/// Какая операция перенесла короб — источник строки журнала размещений (P5-05-1, P6-04).
enum LoadUnitMoveKind {
  /// Приёмка положила короб на склад.
  receipt,

  /// Размещение по заданию.
  putaway,

  /// Перемещение (P6).
  move,

  /// Источник, которого эта версия терминала не знает (появится с новыми операциями) —
  /// подписывается нейтрально, а не выдаётся за размещение.
  other,
}

/// Перенос короба: откуда, куда, кто и когда (P5-05-1).
class LoadUnitMove {
  const LoadUnitMove({
    this.from,
    required this.to,
    required this.kind,
    this.userName,
    required this.at,
  });

  /// `null` — первое размещение: короб появился на складе.
  final String? from;
  final String to;

  /// Какая операция перенесла короб.
  final LoadUnitMoveKind kind;
  final String? userName;
  final DateTime at;
}

/// История короба: создание и переносы по порядку (P5-05-1). Только со связью.
class LoadUnitHistory {
  const LoadUnitHistory({
    required this.createdAt,
    this.receipt,
    this.moves = const [],
  });

  final DateTime createdAt;

  /// `null` — короб не попал ни в одну приёмку.
  final LoadUnitReceiptInfo? receipt;
  final List<LoadUnitMove> moves;
}

/// Короткий код с ярлыка для поиска: без пробелов и дефисов, заглавными; `null` — не код
/// (нужны 1…8 знаков 0–9, A–F). Правило то же, что на сервере, — иначе терминал искал бы
/// то, что сервер отвергнет.
String? shortCodeQuery(String input) {
  final code = input.replaceAll(RegExp(r'[\s-]'), '').toUpperCase();
  return RegExp(r'^[0-9A-F]{1,8}$').hasMatch(code) ? code : null;
}

/// Совпадает ли короб с кодом [code] (уже приведённым [shortCodeQuery]): код входит в последние
/// восемь знаков идентификатора — их печатает ярлык.
bool matchesShortCode(String loadUnitId, String code) {
  final hex = loadUnitId.replaceAll('-', '').toUpperCase();
  final tail = hex.length > 8 ? hex.substring(hex.length - 8) : hex;
  return tail.contains(code);
}
