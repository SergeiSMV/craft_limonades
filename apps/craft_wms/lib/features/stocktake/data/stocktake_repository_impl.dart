import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:either_dart/either.dart';
import 'package:injectable/injectable.dart';

import '../../../core/database/app_database.dart';
import '../../../core/error/failure.dart';
import '../../../core/outbox/outbox_operation.dart';
import '../../../core/outbox/outbox_repository.dart';
import '../../../core/sync/sync_engine.dart';
import '../../../core/warehouse/internal_warehouses.dart';
import '../../tasks/data/tasks_repository.dart';
import '../domain/stocktake_models.dart';
import '../domain/stocktake_repository.dart';
import 'stocktake_api.dart';

/// Пересчёт на ТСД (P10-04): сеть - через [StocktakeApi], факт ячейки - операцией очереди тем
/// же путём, что размещение и возврат: в очередь и сразу попытка отправить.
///
/// Черновики подсчёта лежат в общей таблице черновиков строкой на ячейку (`stocktake:<id>`):
/// ячеек у работника может быть несколько, и каждая переживает перезапуск приложения.
@LazySingleton(as: StocktakeRepository)
class StocktakeRepositoryImpl implements StocktakeRepository {
  StocktakeRepositoryImpl(
    this._api,
    this._outbox,
    this._sync,
    this._tasks,
    this._warehouses,
    this._db,
  );

  final StocktakeApi _api;
  final OutboxRepository _outbox;
  final SyncEngine _sync;
  final TasksRepository _tasks;
  final InternalWarehouses _warehouses;
  final AppDatabase _db;

  static const _draftPrefix = 'stocktake:';

  @override
  Future<Either<Failure, StocktakeInfo>> stocktake(String id) =>
      _api.stocktake(id);

  @override
  Future<Either<Failure, List<StocktakeCell>>> cells(String stocktakeId) =>
      _api.cells(stocktakeId);

  @override
  Future<Either<Failure, void>> take(String cellId) => _api.take(cellId);

  @override
  Future<Either<Failure, void>> release(String cellId) async {
    final res = await _api.release(cellId);
    if (res.isRight) await _clearDraft(cellId);
    return res;
  }

  /// Склад позиций приводится к соглашению терминала: «Основной» - `null`.
  @override
  Future<Either<Failure, StocktakeCellView>> start(String cellId) async {
    final res = await _api.start(cellId);
    if (res.isLeft) return res;
    final def = await _warehouses.defaultId();
    final view = res.right;
    return Right(
      view.copyWith(
        positions: [
          for (final p in view.positions)
            p.copyWith(
              internalWarehouseId: InternalWarehouses.normalize(
                p.internalWarehouseId,
                def,
              ),
            ),
        ],
      ),
    );
  }

  @override
  Future<Either<Failure, void>> submit(
    String cellId,
    Map<String, dynamic> payload,
  ) async {
    final operationId = await _outbox.enqueue(
      kind: OutboxKind.stocktakeCellSubmit,
      payload: payload,
    );
    await _clearDraft(cellId);
    final operation = await _outbox.byOperationId(operationId);
    if (operation == null) return const Right(null);
    final res = await _sync.sendOne(operation);
    // Ход пересчёта на плитке задания - свежим, раз сервер подсчёт принял.
    if (res.isRight) await _tasks.current();
    return res;
  }

  @override
  Future<Map<String, dynamic>?> loadDraft(String cellId) async {
    final row = await (_db.select(
      _db.entryDrafts,
    )..where((t) => t.id.equals('$_draftPrefix$cellId'))).getSingleOrNull();
    return row == null ? null : _decode(row.payload);
  }

  @override
  Future<void> saveDraft(String cellId, Map<String, dynamic> draft) => _db
      .into(_db.entryDrafts)
      .insertOnConflictUpdate(
        EntryDraftsCompanion.insert(
          id: Value('$_draftPrefix$cellId'),
          payload: jsonEncode(draft),
          updatedAt: DateTime.now(),
        ),
      );

  @override
  Future<List<Map<String, dynamic>>> drafts(String stocktakeId) async {
    final rows = await (_db.select(
      _db.entryDrafts,
    )..where((t) => t.id.like('$_draftPrefix%'))).get();
    final out = <Map<String, dynamic>>[];
    for (final r in rows) {
      final d = _decode(r.payload);
      final cell = (d?['view'] as Map?)?['cell'] as Map?;
      if (d != null && cell?['stocktake_id'] == stocktakeId) out.add(d);
    }
    return out;
  }

  Future<void> _clearDraft(String cellId) => (_db.delete(
    _db.entryDrafts,
  )..where((t) => t.id.equals('$_draftPrefix$cellId'))).go();

  /// Битый слепок - как его отсутствие: уронить экран из-за него нельзя.
  Map<String, dynamic>? _decode(String payload) {
    try {
      return jsonDecode(payload) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<Either<Failure, StocktakeCreated>> create({
    required String warehouseId,
    required String scopeKind,
    List<String> objectIds = const [],
  }) => _api.create({
    'warehouse_id': warehouseId,
    'scope_kind': scopeKind,
    'object_ids': objectIds,
  });

  @override
  Future<Either<Failure, void>> close(String id, {required bool force}) async {
    final res = await _api.close(id, force: force);
    if (res.isRight) await _tasks.current();
    return res;
  }
}
