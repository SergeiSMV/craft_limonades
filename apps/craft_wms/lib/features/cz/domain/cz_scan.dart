import 'package:either_dart/either.dart';

import '../../../core/error/failure.dart';

/// Вид кода по ответу «Честного знака» (`generalPackageType`).
enum CzCodeKind {
  /// Марка единицы товара.
  unit,

  /// Групповая упаковка (6X, 12X): КИ того же вида, что у марки.
  group,

  /// Транспортный короб (`00`+SSCC); в WMS — грузовая единица.
  box,
}

/// Товар справочника, найденный по GTIN марки.
class CzGood {
  const CzGood({required this.id, required this.name});

  final String id;
  final String name;
}

/// Что о марке знает WMS: статус, место, когда пришла. В CZ-04 это и есть история марки;
/// журнал движений появится вместе с движением марок (CZ-06).
class CzMarkInWms {
  const CzMarkInWms({
    required this.status,
    required this.receivedAt,
    this.loadUnitId,
    this.loadUnitCellId,
    this.cellId,
    this.aggregateCode,
    this.cellAddress,
  });

  /// `in_stock`, `shipped`, `written_off`, `returned`.
  final String status;
  final DateTime receivedAt;

  /// Короб, в котором лежит марка; `null` — россыпь.
  final String? loadUnitId;

  /// Ячейка короба марки; `null` — короб не размещён или марка россыпью.
  final String? loadUnitCellId;

  /// Ячейка марки россыпью.
  final String? cellId;

  /// Упаковка ЧЗ, в которой марка пришла.
  final String? aggregateCode;

  /// Адрес ячейки, где марка лежит (короба или своей); `null` — места нет.
  final String? cellAddress;

  bool get inStock => status == 'in_stock';
}

/// Строка состава упаковки: единицы одного товара и одной партии — даты производства единицы.
class CzCompositionLine {
  const CzCompositionLine({
    required this.gtin,
    required this.productName,
    required this.producedDate,
    required this.count,
    required this.cis,
    this.good,
  });

  final String gtin;

  /// Наименование по ЧЗ; может отличаться от номенклатуры.
  final String productName;

  /// Товар справочника; `null` — GTIN не привязан к товару.
  final CzGood? good;
  final DateTime? producedDate;
  final int count;
  final List<String> cis;
}

/// Ответ на скан марки или кода короба (CZ-04).
///
/// Наименование по ЧЗ и товар справочника — разные поля: на марке название может не совпадать
/// с номенклатурой 1С, товар определяет привязка ШК, а не название.
class CzScanResult {
  const CzScanResult({
    required this.code,
    required this.kind,
    this.productName,
    this.gtin,
    this.productGroup,
    this.status,
    this.ownerInn,
    this.ownerName,
    this.producedDate,
    this.expirationDate,
    this.parent,
    this.good,
    this.bindBarcode,
    this.mark,
    this.loadUnitId,
    this.composition = const [],
    this.units = 0,
    this.unreadable = const [],
  });

  /// Код, приведённый сервером к ключу ЧЗ (КИ или `00`+SSCC).
  final String code;
  final CzCodeKind kind;

  // Данные ЧЗ по коду.
  final String? productName;
  final String? gtin;
  final String? productGroup;

  /// Статус в обороте по ЧЗ: `INTRODUCED`, `RETIRED`…
  final String? status;
  final String? ownerInn;
  final String? ownerName;
  final DateTime? producedDate;
  final DateTime? expirationDate;

  /// Упаковка ЧЗ, в которой лежит код.
  final String? parent;

  /// Товар справочника по GTIN; `null` — GTIN незнаком, тогда [bindBarcode] — какой ШК
  /// предложить привязать (EAN-13: GTIN без ведущего нуля).
  final CzGood? good;
  final String? bindBarcode;

  /// Марка в WMS; `null` — не числится.
  final CzMarkInWms? mark;

  /// Принятый короб ЧЗ — грузовая единица WMS; `null` — короб не принят.
  final String? loadUnitId;

  /// Состав упаковки до единиц, по товару и партии.
  final List<CzCompositionLine> composition;
  final int units;

  /// Вложенные коды, по которым ЧЗ отказал.
  final List<String> unreadable;
}

/// Чтение «Честного знака» по скану. Только онлайн: ЧЗ без связи не читается.
/// Реализация — `CzScanRepositoryImpl` в `data`.
abstract interface class CzScanRepository {
  /// Данные по коду со сканера: префикс AIM и криптохвост сервер срежет сам.
  Future<Either<Failure, CzScanResult>> scan(String code);
}
