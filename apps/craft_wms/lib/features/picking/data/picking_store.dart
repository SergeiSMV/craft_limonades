import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:injectable/injectable.dart';

import '../../../core/database/app_database.dart';
import '../domain/picking_models.dart';

/// Слепки заказов сборки на терминале (P9-06): строка на заказ в общей таблице черновиков
/// (`picking:<id>`), как подсчёты ячеек пересчёта.
///
/// Зачем: пик идёт и без связи, а что собирать и что уже взято, знает только последний ответ
/// сервера. Слепок переживает выход с экрана и перезапуск приложения.
@lazySingleton
class PickingStore {
  PickingStore(this._db);

  final AppDatabase _db;

  static const _prefix = 'picking:';

  Future<PickingOrderDraft?> load(String orderId) async {
    final row = await (_db.select(
      _db.entryDrafts,
    )..where((t) => t.id.equals('$_prefix$orderId'))).getSingleOrNull();
    return row == null ? null : _decode(row.payload);
  }

  Future<void> save(PickingOrderDraft draft) => _db
      .into(_db.entryDrafts)
      .insertOnConflictUpdate(
        EntryDraftsCompanion.insert(
          id: Value('$_prefix${draft.order.id}'),
          payload: jsonEncode(draft.toJson()),
          updatedAt: DateTime.now(),
        ),
      );

  Future<void> remove(String orderId) => (_db.delete(
    _db.entryDrafts,
  )..where((t) => t.id.equals('$_prefix$orderId'))).go();

  /// Все слепки - свежие сверху.
  Future<List<PickingOrderDraft>> all() async {
    final rows =
        await (_db.select(_db.entryDrafts)
              ..where((t) => t.id.like('$_prefix%'))
              ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)]))
            .get();
    return rows.map((r) => _decode(r.payload)).nonNulls.toList();
  }

  /// Битый слепок - как его отсутствие: уронить экран из-за него нельзя.
  PickingOrderDraft? _decode(String payload) {
    try {
      return PickingOrderDraft.fromJson(
        jsonDecode(payload) as Map<String, dynamic>,
      );
    } catch (_) {
      return null;
    }
  }
}
