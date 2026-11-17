/// Даты и время для экранов ТСД - по часам терминала.
///
/// Вынесено из раздела «ЗАДАНИЯ» (P5-05, P5-05-1): те же форматы нужны экранам содержимого
/// ячейки и короба - «данные на 07.10 14:30», история короба, - и второй экземпляр разошёлся бы
/// с первым.
library;

String _two(int v) => v.toString().padLeft(2, '0');

/// «05.10.2026».
String fullDate(DateTime d) {
  final l = d.toLocal();
  return '${_two(l.day)}.${_two(l.month)}.${l.year}';
}

/// «05.10.2026 13:58».
String fullDateTime(DateTime d) => '${fullDate(d)} ${timeOfDay(d)}';

/// «14:30».
String timeOfDay(DateTime d) {
  final l = d.toLocal();
  return '${_two(l.hour)}:${_two(l.minute)}';
}

/// «07.10 14:30».
String shortDateTime(DateTime d) {
  final l = d.toLocal();
  return '${_two(l.day)}.${_two(l.month)} ${_two(l.hour)}:${_two(l.minute)}';
}

/// Дата партии из транспорта DD-MM-YYYY в привычную DD.MM.YYYY.
String batchDate(String transport) => transport.replaceAll('-', '.');
