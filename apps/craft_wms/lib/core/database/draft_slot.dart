import 'dart:convert';

import 'package:drift/drift.dart';

import 'app_database.dart';

/// Ячейка для черновика незавершённой работы кладовщика — одна строка таблицы `entry_drafts`.
///
/// Что: сохранить, прочитать, стереть слепок и следить, есть ли он.
/// Зачем: работа копится на терминале и уходит на сервер одним махом в конце (проход «Ввода
///        остатков», приёмка). До этого момента падение приложения, разряд батареи или выгрузка
///        процесса Android'ом теряли бы её целиком — при исправной сети тоже.
/// Как: строка на поток, ключ задаёт наследник ([key]); слепок лежит строкой JSON.
///
/// Слот ничего не знает о классе состояния экрана: принимает и отдаёт `Map<String, dynamic>`.
/// Собирает и разбирает слепок сам cubit — иначе слой данных пришлось бы завязать на
/// presentation, а это ровно обратное направление зависимости.
///
/// Общий класс, а не копия на каждый поток (P4-09): правила у черновиков одни, и две копии
/// разошлись бы на первой же правке — например, на обработке битого слепка.
abstract class DraftSlot {
  DraftSlot(this._db, this.key);

  final AppDatabase _db;

  /// Ключ строки: один черновик на поток.
  final String key;

  /// Сохранить слепок (перезаписывает предыдущий).
  Future<void> save(Map<String, dynamic> draft) => _db
      .into(_db.entryDrafts)
      .insertOnConflictUpdate(
        EntryDraftsCompanion.insert(
          id: Value(key),
          payload: jsonEncode(draft),
          updatedAt: DateTime.now(),
        ),
      );

  /// Прочитать слепок; `null` — незавершённой работы нет.
  ///
  /// Битый JSON тоже даёт `null`: слепок пишется целиком, и если он не разбирается, значит
  /// запись оборвалась или формат сменился. Уронить экран из-за этого нельзя — лучше начать
  /// с чистого листа, чем не дать работать вовсе.
  Future<Map<String, dynamic>?> load() async {
    final query = _db.select(_db.entryDrafts)..where((t) => t.id.equals(key));
    final row = await query.getSingleOrNull();
    if (row == null) return null;
    try {
      return jsonDecode(row.payload) as Map<String, dynamic>;
    } catch (_) {
      await clear();
      return null;
    }
  }

  /// Есть ли незавершённая работа — живой признак для пометки на входе в раздел (ADHOC-13).
  ///
  /// Черновик лежит в своей таблице, и индикатор очереди (P2-07) его не видит — он считает
  /// только строки `outbox_operations`. Без пометки на устройстве могла бы ждать целая
  /// работа, а шапка показывала бы «всё отправлено».
  ///
  /// Смотрим только НАЛИЧИЕ строки: содержимое слепка пометке не нужно, а разбирать JSON на
  /// каждое изменение базы — лишняя работа на каждый скан.
  Stream<bool> watchHasDraft() {
    final query = _db.selectOnly(_db.entryDrafts)
      ..addColumns([_db.entryDrafts.id])
      ..where(_db.entryDrafts.id.equals(key));
    return query.watch().map((rows) => rows.isNotEmpty);
  }

  /// Убрать слепок — работа завершена или брошена осознанно.
  Future<void> clear() =>
      (_db.delete(_db.entryDrafts)..where((t) => t.id.equals(key))).go();
}
