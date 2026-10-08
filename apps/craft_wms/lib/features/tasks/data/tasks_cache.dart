import 'dart:convert';

import 'package:injectable/injectable.dart';

import '../../../core/database/app_database.dart';
import 'tasks_models.dart';

/// Снимок текущих заданий в локальной базе (P5-02-1).
///
/// Что: последний удачный ответ `GET /tasks` — для работы без связи.
/// Как: одна строка со списком целиком; запись — замена. Сервер отдаёт текущие целиком, и
///      задание, ушедшее в «Завершённые» или к другому, из снимка пропадает, а не задерживается.
@lazySingleton
class TasksCache {
  TasksCache(this._db);

  final AppDatabase _db;

  /// Заменить снимок.
  Future<void> replace(List<WarehouseTask> tasks, DateTime syncedAt) => _db
      .into(_db.cachedTasks)
      .insertOnConflictUpdate(
        CachedTasksCompanion.insert(
          payload: jsonEncode([for (final t in tasks) t.toJson()]),
          syncedAt: syncedAt,
        ),
      );

  /// Сколько текущих заданий в снимке — для счётчика на плитке «ЗАДАНИЯ».
  ///
  /// Поток, а не разовое чтение: снимок обновляют и раздел «Задания», и главный экран, и
  /// плитка должна меняться вместе с ним, а не только при перерисовке меню.
  Stream<int> watchCount() =>
      _db.select(_db.cachedTasks).watchSingleOrNull().map((row) {
        if (row == null) return 0;
        final raw = jsonDecode(row.payload);
        return raw is List ? raw.length : 0;
      });

  /// Снимок: задания в порядке сервера и момент получения. null — снимка ещё нет.
  Future<(List<WarehouseTask>, DateTime)?> read() async {
    final row = await _db.select(_db.cachedTasks).getSingleOrNull();
    if (row == null) return null;
    final tasks = <WarehouseTask>[];
    final raw = jsonDecode(row.payload);
    if (raw is List) {
      for (final e in raw) {
        // Задание, которое не разобрать (его писала другая версия приложения), пропускаем:
        // одно испорченное не должно прятать остальные.
        try {
          tasks.add(WarehouseTask.fromJson(e as Map<String, dynamic>));
        } catch (_) {}
      }
    }
    return (tasks, row.syncedAt);
  }
}
