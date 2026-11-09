import '../../contents/domain/contents_entities.dart';
import 'picking_models.dart';
import 'picking_view.dart';

/// Откуда взять по скану (P9-06): что из отсканированного источника идёт в какую строку заказа.
///
/// Скан говорит, где кладовщик стоит: россыпь - сканом ячейки, товар в коробе - сканом короба
/// (короб сам знает свою ячейку), маркируемый - сканом марки или короба ЧЗ. Чистые функции -
/// без Flutter и базы: экран находит ячейку, короб и марки по снимку терминала и передаёт сюда.

/// Вариант пика: строка, источник, партия и сколько там можно взять.
class PickCandidate {
  const PickCandidate({
    required this.line,
    this.sourceCellId,
    this.sourceLoadUnitId,
    required this.cellAddress,
    required this.productionDate,
    this.internalWarehouseId = '',
    required this.available,
  });

  final PickingLine line;
  final String? sourceCellId;
  final String? sourceLoadUnitId;
  final String cellAddress;

  /// Дата партии, DD-MM-YYYY.
  final String productionDate;

  /// Склад россыпи, как ждёт сервер: пусто - «Основной».
  final String internalWarehouseId;

  /// Сколько в источнике можно взять по данным терминала - не больше остатка строки.
  final double available;
}

/// Партия подбора YYYY-MM-DD → транспортный вид DD-MM-YYYY.
String transportDate(String iso) {
  final p = iso.split('-');
  return p.length == 3 ? '${p[2]}-${p[1]}-${p[0]}' : iso;
}

/// Строки, которые собирают обычным пиком: живые, не маркируемые, не собранные.
Iterable<PickingLine> _openLines(
  PickingOrderView view, {
  required bool marked,
}) => view.activeLines.where(
  (l) => l.czMarked == marked && l.goodId != null && !view.done(l),
);

double _min(double a, double b) => a < b ? a : b;

/// Варианты по подбору сервера: россыпь ячейки [cellAddress] или короб [loadUnitId].
List<PickCandidate> candidatesFromTakes(
  PickingOrderView view, {
  String? cellAddress,
  String? loadUnitId,
}) {
  final addr = cellAddress?.toLowerCase();
  final box = loadUnitId?.toLowerCase();
  final out = <PickCandidate>[];
  for (final line in _openLines(view, marked: false)) {
    for (final take in line.suggestion?.takes ?? const <PickingTake>[]) {
      final match = box != null
          ? take.fromBox && take.loadUnitId!.toLowerCase() == box
          : !take.fromBox && take.cellAddress.toLowerCase() == addr;
      if (!match) continue;
      out.add(
        PickCandidate(
          line: line,
          sourceCellId: take.fromBox ? null : take.cellId,
          sourceLoadUnitId: take.fromBox ? take.loadUnitId : null,
          cellAddress: take.cellAddress,
          productionDate: transportDate(take.batchDate),
          internalWarehouseId: take.fromBox ? '' : take.internalWarehouseId,
          available: _min(take.qty, view.remaining(line)),
        ),
      );
    }
  }
  return out;
}

/// Варианты по содержимому источника из снимка терминала - когда подбор сервера его не назвал.
///
/// [contents] - россыпь ячейки [cellId] или состав короба [loadUnitId]; склад россыпи - по
/// соглашению терминала (`null` - «Основной»). Доступно - остаток минус «в сборке».
List<PickCandidate> candidatesFromContents(
  PickingOrderView view, {
  required List<ContentLine> contents,
  required String cellAddress,
  String? cellId,
  String? loadUnitId,
}) {
  final out = <PickCandidate>[];
  for (final line in _openLines(view, marked: false)) {
    for (final c in contents) {
      if (c.goodId != line.goodId) continue;
      final free = c.qty - c.inPicking;
      if (free <= 0) continue;
      out.add(
        PickCandidate(
          line: line,
          sourceCellId: loadUnitId == null ? cellId : null,
          sourceLoadUnitId: loadUnitId,
          cellAddress: cellAddress,
          productionDate: c.productionDate,
          internalWarehouseId: loadUnitId == null
              ? (c.internalWarehouseId ?? '')
              : '',
          available: _min(free, view.remaining(line)),
        ),
      );
    }
  }
  return out;
}

/// Почему марки не взять.
enum MarkPickProblem {
  /// Марки нет на складе по снимку терминала.
  unknown,

  /// Все марки уже взяты по этому заказу.
  already,

  /// В упаковке разные товары, партии или места - только марками поштучно.
  mixed,

  /// Товара марки нет среди несобранных маркируемых строк заказа.
  noLine,

  /// Марок больше, чем осталось собрать: короб больше нужного не берут - марками поштучно.
  tooMany,
}

/// Пик марками: строка, источник и КИ - или причина отказа.
typedef MarkPick = ({
  PickCandidate? candidate,
  List<String> marks,
  MarkPickProblem? problem,
});

/// Марки [found] по скану марки, групповой упаковки или короба ЧЗ - в одну строку заказа.
///
/// [cellAddressOf] - адрес ячейки марки (у марки в коробе - ячейки короба), для показа.
MarkPick candidateFromMarks(
  PickingOrderView view, {
  required List<StockMark> found,
  required String Function(StockMark mark) cellAddressOf,
}) {
  MarkPick fail(MarkPickProblem p) =>
      (candidate: null, marks: const [], problem: p);
  if (found.isEmpty) return fail(MarkPickProblem.unknown);
  final picked = view.pickedMarks;
  final fresh = found.where((m) => !picked.contains(m.cis)).toList();
  if (fresh.isEmpty) return fail(MarkPickProblem.already);
  final first = fresh.first;
  bool same(StockMark m) =>
      m.goodId == first.goodId &&
      m.productionDate == first.productionDate &&
      m.loadUnitId == first.loadUnitId &&
      m.cellId == first.cellId &&
      m.internalWarehouseId == first.internalWarehouseId;
  if (!fresh.every(same)) return fail(MarkPickProblem.mixed);
  final lines = _openLines(
    view,
    marked: true,
  ).where((l) => l.goodId == first.goodId).toList();
  if (lines.isEmpty) return fail(MarkPickProblem.noLine);
  // Строка той же партии реестра - первой, затем без партии, затем любая.
  final line =
      lines
          .where(
            (l) =>
                l.batchDate != null &&
                transportDate(l.batchDate!) == first.productionDate,
          )
          .firstOrNull ??
      lines.where((l) => l.batchDate == null).firstOrNull ??
      lines.first;
  if (fresh.length > view.remaining(line)) {
    return fail(MarkPickProblem.tooMany);
  }
  return (
    candidate: PickCandidate(
      line: line,
      sourceCellId: first.inBox ? null : first.cellId,
      sourceLoadUnitId: first.loadUnitId,
      cellAddress: cellAddressOf(first),
      productionDate: first.productionDate,
      internalWarehouseId: first.inBox ? '' : (first.internalWarehouseId ?? ''),
      available: fresh.length.toDouble(),
    ),
    marks: [for (final m in fresh) m.cis],
    problem: null,
  );
}
