import '../../../../../core/gen/strings.g.dart';
import '../../../../../core/utils/qty_format.dart';
import '../../../data/tasks_models.dart';

/// Форматирование раздела «ЗАДАНИЯ»: вид, основание, даты, количества.

/// Название вида задания.
String taskKindLabel(String kind) => switch (kind) {
  TaskKind.putaway => t.tasks.kindPutaway,
  _ => kind,
};

/// Основание задания: «Основание: приёмка от 05.10.2026 ИП Березин …».
String taskBasis(WarehouseTask task) {
  final date = fullDate(task.receivedAt ?? task.createdAt);
  return task.supplier.isEmpty
      ? t.tasks.basisReceiptNoSupplier(date: date)
      : t.tasks.basisReceipt(date: date, supplier: task.supplier);
}

/// Автор задания. Задание от приёмки заводит система — «автоматически». Когда задания начнут
/// создавать люди (портал, P8; пересчёт, P10), сервер начнёт отдавать автора, и он встанет здесь.
String taskAuthor(WarehouseTask task) =>
    t.tasks.author(name: t.tasks.authorAuto);

/// Поставщик-основание для ленты, где приёмки как объекта нет — только имя.
String supplierBasis(String supplier) => supplier.isEmpty
    ? t.tasks.fromReceiptNoSupplier
    : t.tasks.fromReceipt(supplier: supplier);

String _two(int v) => v.toString().padLeft(2, '0');

/// «05.10.2026» — по часам терминала.
String fullDate(DateTime d) {
  final l = d.toLocal();
  return '${_two(l.day)}.${_two(l.month)}.${l.year}';
}

/// «05.10.2026 13:58» — по часам терминала.
String fullDateTime(DateTime d) => '${fullDate(d)} ${timeOfDay(d)}';

/// «07.10 14:30» — по часам терминала.
String shortDateTime(DateTime d) {
  final l = d.toLocal();
  return '${_two(l.day)}.${_two(l.month)} ${_two(l.hour)}:${_two(l.minute)}';
}

/// «14:30» — время внутри дня ленты.
String timeOfDay(DateTime d) {
  final l = d.toLocal();
  return '${_two(l.hour)}:${_two(l.minute)}';
}

/// Разделитель дня ленты: «Сегодня», «Вчера» или дата.
String dayLabel(DateTime day, {DateTime? now}) {
  final n = (now ?? DateTime.now()).toLocal();
  final today = DateTime(n.year, n.month, n.day);
  if (day == today) return t.tasks.today;
  if (day == today.subtract(const Duration(days: 1))) return t.tasks.yesterday;
  return '${_two(day.day)}.${_two(day.month)}.${day.year}';
}

/// Дата партии из транспорта DD-MM-YYYY в привычную DD.MM.YYYY.
String batchDate(String transport) => transport.replaceAll('-', '.');

/// Количество из строки сервера без хвостовых нулей: «12.000» → «12».
String qtyText(String? raw) => fmtQty(double.tryParse(raw ?? '') ?? 0);
