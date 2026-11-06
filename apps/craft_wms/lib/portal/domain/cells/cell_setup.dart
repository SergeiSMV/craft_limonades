/// Ячейка страницы «Ячейки» портала (ADHOC-57): адрес, стеллаж и настройки этикетки на балку.
///
/// Ярус и позиция — два последних числа адреса (`B-1-3-7` — ярус 3, позиция 7): по ним идёт
/// порядок наклейки и строки карточки на стойку. Адрес другого вида — без яруса и позиции.
class CellSetup {
  CellSetup({
    required this.id,
    required this.address,
    required this.rackId,
    required this.rackCode,
    required this.isFloor,
    required this.labelSmall,
    required this.labelBarcode,
    this.sideCard = false,
    this.isFloorStorage = false,
  }) : _numbers = _tail(address);

  final String id;
  final String address;

  /// Стеллаж; `null` — ячейка без стеллажа: печатается на балку, но не на карточку.
  final String? rackId;
  final String? rackCode;

  /// Нижняя ячейка — стрелка вниз на этикетке (тот же признак «напольная», что на ТСД).
  final bool isFloor;

  /// Малая балка: этикетка 190 × 46 мм вместо 190 × 69.
  final bool labelSmall;

  /// Штрих-код Code128 на этикетке балки.
  final bool labelBarcode;

  /// Строка на карточке своего стеллажа на стойке; бывает только у ячейки со стеллажом.
  final bool sideCard;

  /// Напольное хранение у стеллажа, адрес на «-Н-П» (ADHOC-61): ведётся вручную, без стеллажа;
  /// на этикетке — QR с адресом вместо штрих-кода.
  final bool isFloorStorage;

  final (int, int)? _numbers;

  int? get tier => _numbers?.$1;
  int? get position => _numbers?.$2;

  /// Копия с другими признаками — несохранённые галочки в образце этикетки.
  CellSetup copyWith({bool? isFloor, bool? labelSmall, bool? labelBarcode}) =>
      CellSetup(
        id: id,
        address: address,
        rackId: rackId,
        rackCode: rackCode,
        isFloor: isFloor ?? this.isFloor,
        labelSmall: labelSmall ?? this.labelSmall,
        labelBarcode: labelBarcode ?? this.labelBarcode,
        sideCard: sideCard,
        isFloorStorage: isFloorStorage,
      );

  /// Два последних числа адреса; меньше двух чисел в хвосте — `null`.
  static (int, int)? _tail(String address) {
    final parts = address.split('-');
    if (parts.length < 2) return null;
    final tier = int.tryParse(parts[parts.length - 2]);
    final pos = int.tryParse(parts.last);
    return tier == null || pos == null ? null : (tier, pos);
  }
}

/// Стеллаж склада: группировка ячеек — для фильтра и печати карточек на стойку.
class Rack {
  const Rack({required this.id, required this.code});

  final String id;
  final String code;
}

/// Всё для страницы: ячейки склада (без ячейки приёмки) и его стеллажи.
class CellsSetup {
  const CellsSetup({
    required this.warehouse,
    required this.cells,
    required this.racks,
  });

  final String warehouse;
  final List<CellSetup> cells;
  final List<Rack> racks;
}

/// Галочка ячейки: три признака этикетки на балку и строка на карточке стеллажа.
enum CellFlag { small, floor, barcode, sideCard }

/// Вид PDF печати: этикетки на большую балку, на малую, карточки на стойку.
enum LabelKind {
  large('large'),
  small('small'),
  cards('cards');

  const LabelKind(this.code);

  /// Значение `kind` в теле `POST /cells/labels.pdf`.
  final String code;
}
