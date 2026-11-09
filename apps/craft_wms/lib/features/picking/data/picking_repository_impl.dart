import 'package:either_dart/either.dart';
import 'package:flutter/foundation.dart';
import 'package:injectable/injectable.dart';
import 'package:uuid/uuid.dart';

import '../../../core/error/failure.dart';
import '../../../core/load_unit/load_unit_id_generator.dart';
import '../../../core/outbox/outbox_operation.dart';
import '../../../core/outbox/outbox_repository.dart';
import '../../../core/outbox/outbox_retry.dart';
import '../../../core/sync/sync_engine.dart';
import '../domain/picking_models.dart';
import '../domain/picking_repository.dart';
import '../domain/picking_card.dart';
import '../domain/picking_shipment.dart';
import '../domain/picking_view.dart';
import 'picking_api.dart';
import 'picking_store.dart';

/// Сборка на ТСД (P9-06): сеть - через [PickingApi], пик и возврат - операциями очереди тем же
/// путём, что размещение и пересчёт: в очередь и сразу попытка отправить.
///
/// Слепок заказа ([PickingStore]) - последний ответ сервера и свои пики. Взятое на экране -
/// ответ плюс свои пики, которых в нём ещё нет ([PickingOrderView.build]); что из своего уже
/// учтено, решает состояние операции в очереди и время запроса заказа.
@LazySingleton(as: PickingRepository)
class PickingRepositoryImpl implements PickingRepository {
  PickingRepositoryImpl(
    this._api,
    this._store,
    this._outbox,
    this._sync,
    this._uuid,
    this._boxIds,
  );

  final PickingApi _api;
  final PickingStore _store;
  final OutboxRepository _outbox;
  final SyncEngine _sync;
  final Uuid _uuid;
  final LoadUnitIdGenerator _boxIds;

  @override
  Future<Either<Failure, List<PickingListItem>>> orders() async {
    final res = await _api.orders();
    if (res.isRight) {
      _activeCount.value = res.right
          .where((o) => !o.picked && (o.mine || !o.busy))
          .length;
    }
    return res;
  }

  final _activeCount = ValueNotifier<int>(0);

  @override
  ValueListenable<int> get activeCount => _activeCount;

  @override
  Future<void> refreshActiveCount() async {
    final res = await orders();
    if (res.isLeft) _activeCount.value = (await onTerminal()).length;
  }

  @override
  Future<Either<Failure, List<PickingListItem>>> shipped(DateTime date) =>
      _api.shipped(
        '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}',
      );

  @override
  Future<List<PickingOrderView>> onTerminal() async {
    final out = <PickingOrderView>[];
    for (final d in await _store.all()) {
      if (!d.order.mine) continue;
      out.add(await _view(d, fromCache: true));
    }
    return out;
  }

  @override
  Future<Either<Failure, PickingOrderView>> order(String id) async {
    // Время - до запроса: операция, подтверждённая во время него, учтётся своей записью, а
    // задвоиться не даст сверка по pick_id.
    final fetchedAt = DateTime.now();
    final res = await _api.order(id);
    final prev = await _store.load(id);
    if (res.isLeft) {
      final failure = res.left;
      // Без связи - слепок; отказ сервера по существу (удалён в 1С, собран) - как есть.
      if (prev != null && isRetryable(failure)) {
        return Right(await _view(prev, fromCache: true));
      }
      return Left(failure);
    }
    final draft = PickingOrderDraft(
      order: res.right,
      fetchedAt: fetchedAt,
      local: await _keep(prev?.local ?? const [], fetchedAt),
      currentBoxId: prev?.currentBoxId,
    );
    await _store.save(draft);
    return Right(await _view(draft));
  }

  @override
  Future<PickingOrderView?> cached(String id, {bool offline = true}) async {
    final d = await _store.load(id);
    return d == null ? null : _view(d, fromCache: offline);
  }

  @override
  Future<Either<Failure, void>> take(String id) => _api.take(id);

  @override
  Future<Either<Failure, void>> release(String id) async {
    final res = await _api.release(id);
    if (res.isRight) {
      final d = await _store.load(id);
      // Свои операции ещё в очереди - слепок нужен, чтобы видеть их на экране.
      if (d != null && (await _keep(d.local, d.fetchedAt)).isEmpty) {
        await _store.remove(id);
      }
    }
    return res;
  }

  @override
  Future<Either<Failure, PickingBox>> addBox(String orderId) async {
    final res = await _api.addBox(orderId, _boxIds.newId());
    if (res.isLeft) return res;
    final box = res.right;
    final d = await _store.load(orderId);
    if (d != null) {
      final boxes = [
        ...d.order.boxes.where((b) => b.loadUnitId != box.loadUnitId),
        box,
      ]..sort((a, b) => a.seq.compareTo(b.seq));
      await _store.save(
        d.copyWith(
          order: d.order.copyWith(boxes: boxes),
          currentBoxId: box.loadUnitId,
        ),
      );
    }
    return res;
  }

  @override
  Future<Either<Failure, void>> dropBox(String orderId, String boxId) async {
    final res = await _api.dropBox(orderId, boxId);
    if (res.isLeft) return res;
    final d = await _store.load(orderId);
    if (d != null) {
      await _store.save(
        d.copyWith(
          order: d.order.copyWith(
            boxes: d.order.boxes.where((b) => b.loadUnitId != boxId).toList(),
          ),
        ),
      );
    }
    return res;
  }

  @override
  Future<void> selectBox(String orderId, String boxId) async {
    final d = await _store.load(orderId);
    if (d != null) await _store.save(d.copyWith(currentBoxId: boxId));
  }

  @override
  Future<Either<Failure, void>> pick(PickRequest r) async {
    final d = await _store.load(r.orderId);
    final view = d == null ? null : await _view(d);
    final boxId = view?.currentBoxId;
    if (d == null || boxId == null) {
      return const Left(Failure.unknown('нет короба отгрузки'));
    }
    final pickId = _uuid.v4();
    final payload = <String, dynamic>{
      'pick_id': pickId,
      'order_id': r.orderId,
      'line_id': r.lineId,
      'box_id': boxId,
      'source_cell_id': r.sourceCellId ?? '',
      'source_load_unit_id': r.sourceLoadUnitId ?? '',
      'internal_warehouse_id': r.sourceLoadUnitId == null
          ? r.internalWarehouseId
          : '',
      'production_date': r.productionDate,
      'qty': r.qty.toString(),
      'marks': r.marks,
    };
    final operationId = await _outbox.enqueue(
      kind: OutboxKind.pickingPick,
      payload: payload,
    );
    final local = LocalPick(
      pick: PickingPick(
        id: pickId,
        lineId: r.lineId,
        boxId: boxId,
        cellAddress: r.cellAddress,
        loadUnitId: r.sourceLoadUnitId,
        productionDate: r.productionDate,
        qty: r.qty,
        marks: r.marks,
      ),
      pickOperationId: operationId,
      sourceCellId: r.sourceCellId,
      internalWarehouseId: r.internalWarehouseId,
      createdAt: DateTime.now(),
    );
    await _store.save(d.copyWith(local: [...d.local, local]));
    final res = await _send(operationId);
    if (res.isLeft && res.left is RejectedFailure) {
      await _drop(r.orderId, pickId);
    }
    return res;
  }

  @override
  Future<Either<Failure, void>> unpick(String orderId, PickingPick pick) async {
    final d = await _store.load(orderId);
    if (d == null) {
      return const Left(Failure.unknown('заказа нет на терминале'));
    }
    final local = d.local.where((l) => l.pick.id == pick.id).firstOrNull;
    // Свой пик ещё в очереди - снимаем его, и на сервер не уходит ни пик, ни возврат.
    if (local != null &&
        await _outbox.discardIfPending(local.pickOperationId)) {
      await _drop(orderId, pick.id);
      return const Right(null);
    }
    final operationId = await _outbox.enqueue(
      kind: OutboxKind.pickingUnpick,
      payload: {'pick_id': pick.id},
    );
    final record =
        (local ??
                LocalPick(
                  pick: pick,
                  pickOperationId: '',
                  createdAt: DateTime.now(),
                ))
            .copyWith(
              unpickOperationId: operationId,
              unpickedAt: DateTime.now(),
            );
    await _store.save(
      d.copyWith(
        local: [...d.local.where((l) => l.pick.id != pick.id), record],
      ),
    );
    final res = await _send(operationId);
    // Отказ возврата - пик остаётся в коробе: снимаем только отметку возврата.
    if (res.isLeft && res.left is RejectedFailure) {
      final now = await _store.load(orderId);
      if (now != null) {
        await _store.save(
          now.copyWith(
            local: [
              for (final l in now.local)
                if (l.pick.id != pick.id)
                  l
                else if (l.pickOperationId.isNotEmpty)
                  l.copyWith(unpickOperationId: null, unpickedAt: null),
            ],
          ),
        );
      }
    }
    return res;
  }

  @override
  Future<Either<Failure, ShortageResult>> shortage(
    String orderId,
    String lineId, {
    required bool shortage,
  }) async {
    final res = await _api.shortage(orderId, lineId, shortage: shortage);
    if (res.isRight) {
      final d = await _store.load(orderId);
      if (d != null) {
        await _store.save(
          d.copyWith(
            order: d.order.copyWith(
              lines: [
                for (final l in d.order.lines)
                  l.id == lineId ? l.copyWith(shortage: shortage) : l,
              ],
            ),
          ),
        );
      }
    }
    return res;
  }

  @override
  Future<Either<Failure, PickingShipment>> complete(String orderId) async {
    // Свои пики и возвраты в очереди - сначала отправить: завершение считает взятое по серверу.
    if (await _hasPending(orderId)) {
      await _sync.drain();
      if (await _hasPending(orderId)) return const Left(Failure.network());
    }
    final res = await _api.complete(orderId);
    // Заказ собран - слепок больше не нужен: пикать в него уже нельзя.
    if (res.isRight) await _store.remove(orderId);
    return res;
  }

  @override
  Future<Either<Failure, PickingShipment>> shipment(String orderId) =>
      _api.shipment(orderId);

  @override
  Future<Either<Failure, PickingShipment>> labels(
    String orderId,
    List<String> boxIds,
  ) => _api.labels(orderId, boxIds);

  @override
  Future<Either<Failure, PickingCard>> card(String orderId) =>
      _api.card(orderId);

  @override
  Future<Either<Failure, PickingShipment>> ship(
    String orderId,
    List<String> boxIds,
  ) => _api.ship(orderId, boxIds);

  /// Есть ли по заказу свои пики или возвраты, ещё не ушедшие на сервер.
  Future<bool> _hasPending(String orderId) async {
    final d = await _store.load(orderId);
    if (d == null) return false;
    final view = await _view(d);
    return view.picks.any((p) => p.pending || p.returnPending);
  }

  /// Отправить операцию очереди сразу.
  Future<Either<Failure, void>> _send(String operationId) async {
    final op = await _outbox.byOperationId(operationId);
    if (op == null) return const Right(null);
    return _sync.sendOne(op);
  }

  /// Убрать свою запись о пике.
  Future<void> _drop(String orderId, String pickId) async {
    final d = await _store.load(orderId);
    if (d == null) return;
    await _store.save(
      d.copyWith(local: d.local.where((l) => l.pick.id != pickId).toList()),
    );
  }

  /// Свои записи, которые ещё нужны поверх ответа сервера, запрошенного в [fetchedAt]:
  /// операция в очереди или подтверждена уже после запроса.
  Future<List<LocalPick>> _keep(
    List<LocalPick> local,
    DateTime fetchedAt,
  ) async {
    final out = <LocalPick>[];
    for (final l in local) {
      if (await _live(l.pickOperationId, fetchedAt) ||
          await _live(l.unpickOperationId, fetchedAt)) {
        out.add(l);
      }
    }
    return out;
  }

  Future<bool> _live(String? operationId, DateTime fetchedAt) async {
    if (operationId == null || operationId.isEmpty) return false;
    final op = await _outbox.byOperationId(operationId);
    if (op == null) return false;
    return switch (op.status) {
      OutboxStatus.pending || OutboxStatus.sending => true,
      OutboxStatus.sent => !op.updatedAt.isBefore(_seconds(fetchedAt)),
      OutboxStatus.rejected => false,
    };
  }

  /// Время очереди база хранит с точностью до секунды: подтверждённое в ту же секунду, что
  /// ушёл запрос заказа, считается подтверждённым после него. Задвоить пик это не может -
  /// пик, уже учтённый сервером, отсекает сверка по `pick_id`.
  DateTime _seconds(DateTime t) => DateTime.fromMillisecondsSinceEpoch(
    t.millisecondsSinceEpoch ~/ 1000 * 1000,
  );

  /// Состояние своей операции относительно ответа, запрошенного в [fetchedAt]: учитывать ли
  /// её поверх ответа и ждёт ли она ещё отправки.
  Future<(bool, bool)> _opState(
    String? operationId,
    DateTime createdAt,
    DateTime fetchedAt,
  ) async {
    if (operationId == null || operationId.isEmpty) return (false, false);
    final op = await _outbox.byOperationId(operationId);
    // Строки уже нет (очередь убрала отправленное): учтена, если сделана до запроса.
    if (op == null) return (createdAt.isAfter(fetchedAt), false);
    return switch (op.status) {
      OutboxStatus.pending || OutboxStatus.sending => (true, true),
      OutboxStatus.sent => (!op.updatedAt.isBefore(_seconds(fetchedAt)), false),
      OutboxStatus.rejected => (false, false),
    };
  }

  Future<PickingOrderView> _view(
    PickingOrderDraft d, {
    bool fromCache = false,
  }) async {
    final states = <String, LocalPickState>{};
    for (final l in d.local) {
      final (picked, pickPending) = await _opState(
        l.pickOperationId,
        l.createdAt,
        d.fetchedAt,
      );
      final (unpicked, unpickPending) = await _opState(
        l.unpickOperationId,
        l.unpickedAt ?? l.createdAt,
        d.fetchedAt,
      );
      states[l.pick.id] = (
        picked: picked,
        pickPending: pickPending,
        unpicked: unpicked,
        unpickPending: unpickPending,
      );
    }
    return PickingOrderView.build(d, states: states, fromCache: fromCache);
  }
}
