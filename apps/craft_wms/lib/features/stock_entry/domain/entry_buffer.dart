import '../../cz/domain/cz_intake.dart';
import '../../stock/domain/catalog_models.dart';
import 'entry_models.dart';

/// Правила буфера ячейки прохода - чистые функции без состояния, чтобы проверяться без cubit.
/// Грань строки - (товар, дата, короб): совпавшая грань копит количество (и марки), иначе -
/// новая строка.

/// Добавить [qty] товара партии [date] россыпью или в короб [boxId].
List<EntryLineDraft> addEntryQty(
  List<EntryLineDraft> lines, {
  required Good good,
  required String date,
  required double qty,
  String? boxId,
}) {
  final out = List<EntryLineDraft>.from(lines);
  final i = out.indexWhere((l) => l.sameGrain(good.id, date, boxId));
  if (i >= 0) {
    out[i] = out[i].copyWith(qty: out[i].qty + qty);
  } else {
    out.add(
      EntryLineDraft(good: good, productionDate: date, qty: qty, boxId: boxId),
    );
  }
  return out;
}

/// Положить марки ЧЗ в строки россыпью или в короб [boxId]: каждая марка - единица.
List<EntryLineDraft> addEntryMarks(
  List<EntryLineDraft> lines,
  List<CzIntakeLine> add, {
  String? boxId,
}) {
  final out = List<EntryLineDraft>.from(lines);
  for (final a in add) {
    if (a.marks.isEmpty) continue;
    final i = out.indexWhere((l) => l.sameGrain(a.good.id, a.date, boxId));
    if (i >= 0) {
      out[i] = out[i].copyWith(
        qty: out[i].qty + a.marks.length,
        marks: [...out[i].marks, ...a.marks],
      );
    } else {
      out.add(
        EntryLineDraft(
          good: a.good,
          productionDate: a.date,
          qty: a.marks.length.toDouble(),
          boxId: boxId,
          marks: a.marks,
        ),
      );
    }
  }
  return out;
}

/// Слить строки [add] в [base] по грани: количества складываются, марки собираются вместе.
List<EntryLineDraft> mergeEntryLines(
  List<EntryLineDraft> base,
  List<EntryLineDraft> add,
) {
  final out = List<EntryLineDraft>.from(base);
  for (final l in add) {
    final i = out.indexWhere(
      (x) => x.sameGrain(l.good.id, l.productionDate, l.boxId),
    );
    if (i >= 0) {
      out[i] = out[i].copyWith(
        qty: out[i].qty + l.qty,
        marks: [...out[i].marks, ...l.marks],
      );
    } else {
      out.add(l);
    }
  }
  return out;
}

/// Есть ли среди марок [add] уже введённые в проходе ([pass] - все строки прохода) или повтор
/// внутри самих [add]: одну бутылку дважды не ввести.
bool entryMarksTaken(Iterable<EntryLineDraft> pass, List<CzIntakeLine> add) {
  final taken = {
    for (final l in pass)
      for (final m in l.marks) m.cis,
  };
  for (final a in add) {
    for (final m in a.marks) {
      if (!taken.add(m.cis)) return true;
    }
  }
  return false;
}
