import 'package:freezed_annotation/freezed_annotation.dart';

part 'catalog_models.freezed.dart';
part 'catalog_models.g.dart';

/// Модели чтения справочников (P1-07) — ответы API P1-06. JsonKey мапит snake_case бэкенда.

/// Товар (ответ `GET /goods`). Имена группы/поставщика приходят присоединёнными (LEFT JOIN).
@freezed
abstract class Good with _$Good {
  const factory Good({
    required String id,
    String? code,
    required String name,
    @JsonKey(name: 'full_name') String? fullName,
    required String uom,
    @JsonKey(name: 'group_id') String? groupId,
    @JsonKey(name: 'group_name') String? groupName,
    @JsonKey(name: 'supplier_id') String? supplierId,
    @JsonKey(name: 'supplier_name') String? supplierName,
    @JsonKey(name: 'is_active') @Default(true) bool isActive,
  }) = _Good;

  factory Good.fromJson(Map<String, dynamic> json) => _$GoodFromJson(json);
}

/// Узел дерева групп номенклатуры (ответ `GET /nomenclature-groups`).
@freezed
abstract class NomenclatureGroup with _$NomenclatureGroup {
  const factory NomenclatureGroup({
    required String id,
    required String code,
    required String name,
    @JsonKey(name: 'parent_id') String? parentId,
  }) = _NomenclatureGroup;

  factory NomenclatureGroup.fromJson(Map<String, dynamic> json) =>
      _$NomenclatureGroupFromJson(json);
}

/// Поставщик (ответ `GET /suppliers`).
@freezed
abstract class Supplier with _$Supplier {
  const factory Supplier({required String id, required String name}) =
      _Supplier;

  factory Supplier.fromJson(Map<String, dynamic> json) =>
      _$SupplierFromJson(json);
}

/// Физическая ячейка склада (ответ `GET /cells`). Нужна вводу остатков: резолв по адресу + склад.
@freezed
abstract class Cell with _$Cell {
  const factory Cell({
    required String id,
    @JsonKey(name: 'warehouse_id') required String warehouseId,
    required String address,
    @Default('storage') String type,
    @JsonKey(name: 'is_floor') @Default(false) bool isFloor,
    @JsonKey(name: 'is_active') @Default(true) bool isActive,
  }) = _Cell;

  factory Cell.fromJson(Map<String, dynamic> json) => _$CellFromJson(json);
}

/// Штрихкод товара (ответ `GET /goods/{id}/barcodes`, P-FS-12). symbology может быть null.
@freezed
abstract class Barcode with _$Barcode {
  const factory Barcode({required String barcode, String? symbology}) =
      _Barcode;

  factory Barcode.fromJson(Map<String, dynamic> json) =>
      _$BarcodeFromJson(json);
}

/// Привязка «штрихкод → товар» из выгрузки всего справочника (`GET /barcodes`, P2-02).
/// Отличается от [Barcode] наличием `goodId`: там ШК перечисляются внутри известного товара,
/// здесь товар и есть то, что нужно узнать по коду.
@freezed
abstract class BarcodeLink with _$BarcodeLink {
  const factory BarcodeLink({
    required String barcode,
    @JsonKey(name: 'good_id') required String goodId,
    String? symbology,
  }) = _BarcodeLink;

  factory BarcodeLink.fromJson(Map<String, dynamic> json) =>
      _$BarcodeLinkFromJson(json);
}

/// Строка остатка в товарном разрезе (ответ `GET /stock`). qty — строка (decimal с бэкенда,
/// точное дробное; храним как есть, не теряя знаков).
@freezed
abstract class StockItem with _$StockItem {
  const factory StockItem({
    @JsonKey(name: 'cell_id') required String cellId,
    @JsonKey(name: 'cell_address') required String cellAddress,
    @JsonKey(name: 'good_id') required String goodId,
    @JsonKey(name: 'batch_id') required String batchId,
    @JsonKey(name: 'production_date') required String productionDate,
    required String qty,
  }) = _StockItem;

  factory StockItem.fromJson(Map<String, dynamic> json) =>
      _$StockItemFromJson(json);
}

/// Страница списка (ответ-обёртка `{items, total, limit, offset}` API P1-06).
/// Обобщённая, поэтому парсинг элементов передаётся функцией [fromItem] — freezed/json
/// с дженериком не дружит, а ручной разбор проще и без кодогенерации на generic.
class Paged<T> {
  const Paged({
    required this.items,
    required this.total,
    required this.limit,
    required this.offset,
  });

  final List<T> items;
  final int total;
  final int limit;
  final int offset;

  factory Paged.fromJson(
    Map<String, dynamic> json,
    T Function(Map<String, dynamic>) fromItem,
  ) {
    final rawItems = (json['items'] as List<dynamic>? ?? const [])
        .map((e) => fromItem(e as Map<String, dynamic>))
        .toList();
    return Paged(
      items: rawItems,
      total: json['total'] as int? ?? rawItems.length,
      limit: json['limit'] as int? ?? rawItems.length,
      offset: json['offset'] as int? ?? 0,
    );
  }
}
