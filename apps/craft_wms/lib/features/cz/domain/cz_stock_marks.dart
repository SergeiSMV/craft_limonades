import '../../../core/warehouse/internal_warehouses.dart';
import '../../contents/domain/contents_entities.dart';
import '../../contents/domain/contents_repository.dart';
import 'cz_scan.dart';

/// Марки на складе по скану (ADHOC-70): снимок терминала, а если марки в нём нет - сервер.
///
/// Что: пересчёт, перемещение и размещение ищут марку в снимке склада со своей очередью
/// поверх - без сети, скан за скан. Марки в снимке может не быть: её принял другой терминал,
/// а снимок здесь ещё не перечитан. Тогда марка спрашивается у сервера (`cz/scan`), и
/// если WMS знает её на складе - место, товар и партия берутся из ответа.
/// Зачем не всегда сервер: скан марки - самое частое действие, а снимок отвечает сразу и
/// без связи. Без связи промах остаётся промахом, как раньше.
/// Как: с сервера берётся только марка единицы (не упаковка), числящаяся на складе, с
/// товаром и датой производства; иначе - пусто.
Future<List<StockMark>> stockMarksByCode(
  String code, {
  required ContentsRepository contents,
  required CzScanRepository cz,
  required Future<String?> Function() defaultWarehouseId,
}) async {
  final local = await contents.marksByCode(code);
  if (local.isNotEmpty) return local;
  final res = await cz.scan(code);
  if (res.isLeft) return const [];
  final mark = stockMarkFromScan(
    res.right,
    defaultWarehouseId: await defaultWarehouseId(),
  );
  return mark == null ? const [] : [mark];
}

/// Марка на складе из ответа сервера: товар - тот, за которым марка числится в WMS
/// (ADHOC-53), партия - дата производства единицы (ADR-0017). `null` - не марка единицы, не
/// на складе или без товара и даты. Склад «Основной» ([defaultWarehouseId]) - `null`, как в
/// снимке.
StockMark? stockMarkFromScan(
  CzScanResult scan, {
  required String? defaultWarehouseId,
}) {
  final mark = scan.mark;
  final good = scan.good;
  final produced = scan.producedDate;
  if (scan.kind != CzCodeKind.unit ||
      mark == null ||
      !mark.inStock ||
      good == null ||
      produced == null) {
    return null;
  }
  return StockMark(
    cis: scan.code,
    goodId: good.id,
    productionDate: _wireDate(produced),
    loadUnitId: mark.loadUnitId,
    cellId: mark.loadUnitId == null ? mark.cellId : null,
    internalWarehouseId: mark.loadUnitId == null
        ? InternalWarehouses.normalize(
            mark.internalWarehouseId,
            defaultWarehouseId,
          )
        : null,
    aggregateCode: mark.aggregateCode,
  );
}

/// Дата партии в транспортном виде DD-MM-YYYY, как в снимке склада.
String _wireDate(DateTime d) =>
    '${_two(d.day)}-${_two(d.month)}-${d.year.toString().padLeft(4, '0')}';

String _two(int v) => v.toString().padLeft(2, '0');
