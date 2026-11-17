import '../../../../../core/gen/strings.g.dart';
import '../../../../../core/utils/date_time_format.dart';
import '../../../../../core/utils/doc_number.dart';
import '../../../../../core/utils/qty_format.dart';
import '../../../data/tasks_models.dart';

export '../../../../../core/utils/date_time_format.dart'
    show batchDate, fullDate, fullDateTime, shortDateTime, timeOfDay;

/// Форматирование раздела «ЗАДАНИЯ»: вид, основание, даты, количества.

/// Название вида задания.
String taskKindLabel(String kind) => switch (kind) {
  TaskKind.putaway => t.tasks.kindPutaway,
  TaskKind.supplierReturn => t.tasks.kindSupplierReturn,
  TaskKind.stocktake => t.tasks.kindStocktake,
  TaskKind.pickingReturn => t.tasks.kindPickingReturn,
  _ => kind,
};

/// Основание возврата на места (P9-07-1): заказ удалён в 1С или реестр его изменил.
String pickingReturnBasis(TaskPicking p) => p.deleted
    ? t.tasks.basisPickingDeleted
    : p.changedAt == null
    ? t.tasks.basisPickingChangedNoDate
    : t.tasks.basisPickingChanged(date: fullDateTime(p.changedAt!));

/// «Сборка: СБ-000012» - заказ возврата на места (P9-07-1).
String pickingReturnOrder(TaskPicking p) =>
    t.tasks.pickingOrder(number: docNumber(DocKind.picking, p.number));

/// Основание задания: «Основание: документ № ТН-1042 от 01.10.2026 ИП Березин …» (ADHOC-23);
/// у задания от приёмки до ADHOC-23 документа нет - «Основание: приёмка от 05.10.2026 …».
///
/// У возврата поставщику основание - кому везём (ADHOC-31). У размещения по решению
/// «разместить» - номер проблемы склада (ADHOC-55). У пересчёта - сам пересчёт (ADHOC-58):
/// приёмки у него нет, и запасной ветке «приёмка от <дата создания>» он не подходит.
String taskBasis(WarehouseTask task) {
  if (task.stocktake case final st?) return stocktakeLine(st);
  if (task.picking case final p?) return pickingReturnBasis(p);
  if (task.kind == TaskKind.supplierReturn) {
    return t.tasks.basisReturn(supplier: task.supplier);
  }
  if (task.problem case final p?) {
    return t.tasks.basisProblem(number: docNumber(DocKind.problem, p.number));
  }
  final number = task.docNumber;
  final docDate = task.docDate;
  if (number != null && docDate != null) {
    return task.supplier.isEmpty
        ? t.tasks.basisDocNoSupplier(number: number, date: batchDate(docDate))
        : t.tasks.basisDoc(
            number: number,
            date: batchDate(docDate),
            supplier: task.supplier,
          );
  }
  final date = fullDate(task.receivedAt ?? task.createdAt);
  return task.supplier.isEmpty
      ? t.tasks.basisReceiptNoSupplier(date: date)
      : t.tasks.basisReceipt(date: date, supplier: task.supplier);
}

/// Автор задания. Задание от приёмки заводит система - «автоматически». Когда задания начнут
/// создавать люди (портал, P8; пересчёт, P10), сервер начнёт отдавать автора, и он встанет здесь.
///
/// Пересчёт (P10-04) заводит старший смены - сервер отдаёт его имя.
String taskAuthor(WarehouseTask task) => t.tasks.author(
  name: switch (task.stocktake?.createdBy) {
    final name? when name.isNotEmpty => name,
    _ => t.tasks.authorAuto,
  },
);

/// «Пересчёт: ПС-000012» - строка пересчёта задания (ADHOC-58).
String stocktakeLine(TaskStocktake st) =>
    t.tasks.stocktakeLine(number: docNumber(DocKind.stocktake, st.number));

/// Поставщик-основание для ленты, где приёмки как объекта нет - только имя. У возврата -
/// кому везли (ADHOC-31), у размещения по проблеме - её номер (ADHOC-55), у пересчёта -
/// сам пересчёт (ADHOC-58).
String supplierBasis(
  String supplier, {
  String kind = TaskKind.putaway,
  TaskProblem? problem,
  TaskStocktake? stocktake,
  TaskPicking? picking,
}) => stocktake != null
    ? stocktakeLine(stocktake)
    : picking != null
    ? pickingReturnOrder(picking)
    : kind == TaskKind.supplierReturn
    ? t.tasks.returnSupplier(supplier: supplier)
    : problem != null
    ? t.tasks.fromProblem(number: docNumber(DocKind.problem, problem.number))
    : supplier.isEmpty
    ? t.tasks.fromReceiptNoSupplier
    : t.tasks.fromReceipt(supplier: supplier);

String _two(int v) => v.toString().padLeft(2, '0');

/// Разделитель дня ленты: «Сегодня», «Вчера» или дата.
String dayLabel(DateTime day, {DateTime? now}) {
  final n = (now ?? DateTime.now()).toLocal();
  final today = DateTime(n.year, n.month, n.day);
  if (day == today) return t.tasks.today;
  if (day == today.subtract(const Duration(days: 1))) return t.tasks.yesterday;
  return '${_two(day.day)}.${_two(day.month)}.${day.year}';
}

/// Количество из строки сервера без хвостовых нулей: «12.000» → «12».
String qtyText(String? raw) => fmtQty(double.tryParse(raw ?? '') ?? 0);
