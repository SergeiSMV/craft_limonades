import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:injectable/injectable.dart';

import '../../../core/database/app_database.dart';

/// Хранилище незавершённого прохода «Ввода остатков» (P2-03).
///
/// Что: одна строка в локальной базе со слепком буфера прохода.
/// Зачем: проход копится в памяти и уходит на сервер одним махом на «Завершить ввод»
/// (вариант A, P-FastStart). До этого падение приложения, разряд батареи или выгрузка
/// процесса Android'ом теряли **весь** обход склада — а обход это сотни ячеек и часы работы.
/// К офлайну отношения не имеет: терялось и при исправной сети.
/// Как: слепок кладётся строкой JSON, ключ константный — проход на устройстве один.
///
/// Хранилище намеренно ничего не знает о классе состояния экрана: оно принимает и отдаёт
/// `Map<String, dynamic>`. Собирает и разбирает слепок сам cubit — иначе слой данных
/// пришлось бы завязать на presentation, а это ровно обратное направление зависимости.
@lazySingleton
class EntryDraftStore {
  EntryDraftStore(this._db);

  final AppDatabase _db;

  /// Ключ единственной строки: одновременных проходов на устройстве не бывает.
  static const _rowId = 'current';

  /// Сохранить слепок (перезаписывает предыдущий).
  Future<void> save(Map<String, dynamic> draft) => _db
      .into(_db.entryDrafts)
      .insertOnConflictUpdate(
        EntryDraftsCompanion.insert(
          id: const Value(_rowId),
          payload: jsonEncode(draft),
          updatedAt: DateTime.now(),
        ),
      );

  /// Прочитать слепок; `null` — незавершённого прохода нет.
  ///
  /// Битый JSON тоже даёт `null`: слепок пишется целиком, и если он не разбирается, значит
  /// запись оборвалась или формат сменился. Уронить экран ввода из-за этого нельзя — лучше
  /// начать с чистого прохода, чем не дать работать вовсе.
  Future<Map<String, dynamic>?> load() async {
    final query = _db.select(_db.entryDrafts)
      ..where((t) => t.id.equals(_rowId));
    final row = await query.getSingleOrNull();
    if (row == null) return null;
    try {
      return jsonDecode(row.payload) as Map<String, dynamic>;
    } catch (_) {
      await clear();
      return null;
    }
  }

  /// Есть ли незавершённый проход — живой признак для бэйджа на входах в раздел (ADHOC-13).
  ///
  /// Зачем отдельный поток, а не [load]: проход лежит в своей таблице, и индикатор очереди
  /// (P2-07) его не видит — он считает только строки `outbox_operations`. Получалось, что на
  /// устройстве может ждать обход всего склада, а шапка показывает «всё отправлено».
  ///
  /// Смотрим только НАЛИЧИЕ строки: содержимое слепка бэйджу не нужно, а разбирать JSON на
  /// каждое изменение базы — лишняя работа на каждый скан.
  Stream<bool> watchHasDraft() {
    final query = _db.selectOnly(_db.entryDrafts)
      ..addColumns([_db.entryDrafts.id])
      ..where(_db.entryDrafts.id.equals(_rowId));
    return query.watch().map((rows) => rows.isNotEmpty);
  }

  /// Убрать слепок — проход завершён или брошен осознанно.
  Future<void> clear() =>
      (_db.delete(_db.entryDrafts)..where((t) => t.id.equals(_rowId))).go();
}
