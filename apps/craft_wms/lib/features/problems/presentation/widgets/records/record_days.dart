import '../../../domain/problem_records.dart';

/// Элемент списка проблем: разделитель дня или запись.
sealed class RecordEntry {
  const RecordEntry();
}

/// Разделитель - день, к которому относятся записи под ним.
class RecordDay extends RecordEntry {
  const RecordDay(this.day);
  final DateTime day;
}

/// Запись списка.
class RecordItem extends RecordEntry {
  const RecordItem(this.problem);
  final ProblemRecord problem;
}

/// Раскладывает список по дням, как чат: разделитель перед первой записью каждого дня.
/// День решённой - день решения, открытой - день фиксации; по часам терминала, как у
/// «Завершённых» заданий.
List<RecordEntry> groupRecordsByDay(List<ProblemRecord> items) {
  final out = <RecordEntry>[];
  DateTime? current;
  for (final it in items) {
    final local = it.resolvedAtTime.toLocal();
    final day = DateTime(local.year, local.month, local.day);
    if (current != day) {
      out.add(RecordDay(day));
      current = day;
    }
    out.add(RecordItem(it));
  }
  return out;
}
