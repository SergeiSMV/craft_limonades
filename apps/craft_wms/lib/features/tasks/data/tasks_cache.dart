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

  /// Отметить в снимке то, что разместил сеанс, ушедший в очередь без связи (P5-03).
  ///
  /// Зачем: без связи снимок остаётся прежним, и задание показывало бы уже перенесённое как
  /// неразмещённое — кладовщик разместил бы его второй раз, а сервер отклонил бы весь сеанс.
  /// Как: короба отмечаются размещёнными, остаток россыпи уменьшается; задание, по которому
  /// размещено всё, из текущих уходит, иначе возвращается в пул «новым» — ровно как сделает
  /// сервер, когда сеанс до него дойдёт. Следующий удачный запрос заменит снимок целиком.
  Future<void> applyPutaway({
    required String taskId,
    required Set<String> boxes,
    required Map<(String, String), double> loose,
  }) async {
    final snapshot = await read();
    if (snapshot == null) return;
    final (tasks, syncedAt) = snapshot;
    final updated = <WarehouseTask>[];
    for (final task in tasks) {
      if (task.id != taskId) {
        updated.add(task);
        continue;
      }
      final items = [
        for (final it in task.items)
          if (it.isBox)
            boxes.contains(it.loadUnitId) ? it.copyWith(placed: true) : it
          else
            _reduceLoose(it, loose),
      ];
      final next = task.copyWith(
        items: items,
        status: TaskStatus.fresh,
        assigneeName: '',
        takenAt: null,
      );
      if (next.openItems > 0) updated.add(next);
    }
    await replace(updated, syncedAt);
  }

  /// Отметить в снимке позиции возврата отгруженными (ADHOC-31) — сеанс ушёл в очередь без
  /// связи. Задание отгружается целиком, поэтому выполненное из снимка уходит, как у размещения.
  Future<void> applyReturn({
    required String taskId,
    required Set<String> problemIds,
  }) async {
    final snapshot = await read();
    if (snapshot == null) return;
    final (tasks, syncedAt) = snapshot;
    final updated = <WarehouseTask>[];
    for (final task in tasks) {
      if (task.id != taskId) {
        updated.add(task);
        continue;
      }
      final next = task.copyWith(
        items: [
          for (final it in task.items)
            problemIds.contains(it.problemId) ? it.copyWith(placed: true) : it,
        ],
        status: TaskStatus.fresh,
        assigneeName: '',
        takenAt: null,
      );
      if (next.openItems > 0) updated.add(next);
    }
    await replace(updated, syncedAt);
  }

  TaskItem _reduceLoose(TaskItem it, Map<(String, String), double> loose) {
    final key = (it.good?.id ?? '', it.productionDate ?? '');
    final placed = loose[key];
    if (placed == null) return it;
    final left = (double.tryParse(it.remaining ?? '') ?? 0) - placed;
    final rest = left <= 0 ? 0.0 : left;
    return it.copyWith(remaining: '$rest', placed: rest <= 0);
  }

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
