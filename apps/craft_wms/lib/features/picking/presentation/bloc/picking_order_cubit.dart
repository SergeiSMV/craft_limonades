import 'dart:async';

import 'package:either_dart/either.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:injectable/injectable.dart';

import '../../../../core/error/failure.dart';
import '../../../../core/outbox/outbox_operation.dart';
import '../../../../core/outbox/outbox_repository.dart';
import '../../domain/picking_models.dart';
import '../../domain/picking_repository.dart';
import '../../domain/picking_shipment.dart';
import '../../domain/picking_view.dart';

part 'picking_order_cubit.freezed.dart';

/// Подсказка экрана заказа - показывается один раз.
sealed class OrderNotice {
  const OrderNotice();
}

/// Действие не удалось - причина [failure]; `NetworkFailure` - нужна связь.
final class OrderNoticeFailed extends OrderNotice {
  const OrderNoticeFailed(this.failure);
  final Failure failure;
}

/// Заказ взят в работу.
final class OrderNoticeTaken extends OrderNotice {
  const OrderNoticeTaken();
}

/// Отказ от заказа принят - экран закрывается.
final class OrderNoticeReleased extends OrderNotice {
  const OrderNoticeReleased();
}

/// Заведён короб отгрузки «короб [seq]».
final class OrderNoticeBoxAdded extends OrderNotice {
  const OrderNoticeBoxAdded(this.seq);
  final int seq;
}

/// Пик или возврат: [queued] - ушёл в очередь, связи нет.
/// Пустой короб [seq] убран.
final class OrderNoticeBoxDropped extends OrderNotice {
  const OrderNoticeBoxDropped(this.seq);
  final int seq;
}

final class OrderNoticeDone extends OrderNotice {
  const OrderNoticeDone({required this.unpick, required this.queued});
  final bool unpick;
  final bool queued;
}

/// Сервер отказал пику или возврату по существу - причина дословно.
final class OrderNoticeRejected extends OrderNotice {
  const OrderNoticeRejected(this.reason);
  final String reason;
}

/// «Не хватает» поставлена ([set]) или снята; [result] - пересчёт позиции.
final class OrderNoticeShortage extends OrderNotice {
  const OrderNoticeShortage({required this.set, required this.result});
  final bool set;
  final ShortageResult result;
}

/// Сборка завершена (P9-07): заказ с коробами «N из M» - экран переходит к ярлыкам.
final class OrderNoticeCompleted extends OrderNotice {
  const OrderNoticeCompleted(this.shipment);
  final PickingShipment shipment;
}

enum PickingOrderStatus { loading, loaded, error }

/// Заказ сборки на экране (P9-06).
@freezed
abstract class PickingOrderState with _$PickingOrderState {
  const factory PickingOrderState({
    @Default(PickingOrderStatus.loading) PickingOrderStatus status,
    PickingOrderView? view,
    Failure? failure,

    /// Идёт запрос к серверу - кнопки не нажимаются второй раз.
    @Default(false) bool busy,
    OrderNotice? notice,
  }) = _PickingOrderState;
}

/// Заказ сборки (P9-06): взять, отказаться, короба отгрузки, пик и возврат, «не хватает».
///
/// Что: заказ с сервера или из слепка терминала, свои пики поверх. Решения «что за код» -
/// за экраном: у него снимок склада и справочники; кубит выполняет готовый пик.
/// Зачем подписка на очередь: пик подтверждает движок синхронизации в фоне - экран
/// перечитывает заказ, чтобы «взято» было с сервера, а не только из очереди.
///
/// Скорость скана (ADHOC-63): пик показывается из слепка сразу, без ожидания сервера; заказ с
/// сервера перечитывается один раз, когда сканы и отправка стихли на [reloadPause]. Отказ
/// сервера пику приходит из очереди отказов ([OutboxRepository.watchRejected]).
@injectable
class PickingOrderCubit extends Cubit<PickingOrderState> {
  PickingOrderCubit(this._repo, this._outbox, @factoryParam this.orderId)
    : super(const PickingOrderState()) {
    _queue = _outbox.watchPendingCount().listen(_onQueue);
    _rejected = _outbox.watchRejected().listen(_onRejected);
  }

  /// Пауза после последнего пика или отправки, после которой заказ перечитывается с сервера.
  static const reloadPause = Duration(milliseconds: 1500);

  final PickingRepository _repo;
  final OutboxRepository _outbox;
  final String orderId;
  StreamSubscription<int>? _queue;
  StreamSubscription<List<OutboxOperation>>? _rejected;
  int? _pending;
  Timer? _reloadTimer;

  /// Отклонённые операции, о которых уже знаем; `null` - список ещё не пришёл.
  Set<String>? _seenRejected;

  /// Счётчик своих пиков - перечитывание, начатое до пика, не показывает устаревший ответ.
  int _localSeq = 0;

  PickingOrderView? get view => state.view;

  /// Загрузить заказ: сервер, без связи - слепок.
  Future<void> load() async {
    final res = await _repo.order(orderId);
    if (isClosed) return;
    res.fold(
      (f) => emit(
        state.copyWith(
          status: state.view == null ? PickingOrderStatus.error : state.status,
          failure: f,
          notice: state.view == null ? null : OrderNoticeFailed(f),
        ),
      ),
      (v) => emit(
        state.copyWith(
          status: PickingOrderStatus.loaded,
          view: v,
          failure: null,
        ),
      ),
    );
  }

  /// Очередь опустела на шаг - фон что-то отправил: перечитать заказ после паузы.
  void _onQueue(int count) {
    final before = _pending;
    _pending = count;
    if (before != null && count < before && state.view != null) {
      _scheduleReload();
    }
  }

  /// Сервер отказал пику этого заказа в фоне: причина - подсказкой, пик уже снят с экрана
  /// (операция «отклонена»). Первый список - то, что было до экрана: не показываем.
  void _onRejected(List<OutboxOperation> ops) {
    final mine = ops.where(
      (op) =>
          op.kind == OutboxKind.pickingPick &&
          op.payload['order_id'] == orderId,
    );
    final seen = _seenRejected;
    if (seen == null) {
      _seenRejected = {for (final op in mine) op.operationId};
      return;
    }
    final fresh = mine.where((op) => seen.add(op.operationId)).toList();
    if (fresh.isEmpty || isClosed) return;
    emit(
      state.copyWith(notice: OrderNoticeRejected(fresh.first.lastError ?? '')),
    );
    unawaited(_fromCache(offline: false));
  }

  /// Перечитать заказ, когда сканы и отправка стихнут на [reloadPause].
  void _scheduleReload() {
    _reloadTimer?.cancel();
    _reloadTimer = Timer(reloadPause, () => unawaited(_quietReload()));
  }

  /// Перечитать заказ без подсказок: не вышло - слепок со своими пиками.
  Future<void> _quietReload() async {
    final seq = _localSeq;
    final res = await _repo.order(orderId);
    if (isClosed) return;
    if (res.isRight && seq == _localSeq) {
      emit(state.copyWith(view: res.right));
    } else {
      // Пик во время запроса: ответ уже в слепке, а свежий пик - поверх него.
      await _fromCache(offline: res.isLeft);
    }
  }

  /// Перечитать слепок терминала. [offline] - сервер не ответил («нет связи» на экране); после
  /// удачного запроса - `false`, выбор короба пометку не меняет.
  Future<void> _fromCache({bool offline = true}) async {
    final v = await _repo.cached(orderId, offline: offline);
    if (isClosed || v == null) return;
    emit(state.copyWith(view: v));
  }

  Future<void> take() => _online(_repo.take(orderId), const OrderNoticeTaken());

  Future<void> release() async {
    if (state.busy) return;
    emit(state.copyWith(busy: true));
    final res = await _repo.release(orderId);
    if (isClosed) return;
    emit(
      state.copyWith(
        busy: false,
        notice: res.isRight
            ? const OrderNoticeReleased()
            : OrderNoticeFailed(res.left),
      ),
    );
  }

  Future<void> addBox() async {
    if (state.busy) return;
    emit(state.copyWith(busy: true));
    final res = await _repo.addBox(orderId);
    if (isClosed) return;
    emit(
      state.copyWith(
        busy: false,
        notice: res.isRight
            ? OrderNoticeBoxAdded(res.right.seq)
            : OrderNoticeFailed(res.left),
      ),
    );
    if (res.isRight) await _fromCache(offline: false);
  }

  /// Убрать пустой короб, заведённый по ошибке, - со связью; затем заказ заново: номера
  /// коробов сдвинулись.
  Future<void> dropBox(PickingBox box) async {
    if (state.busy) return;
    emit(state.copyWith(busy: true));
    final res = await _repo.dropBox(orderId, box.loadUnitId);
    if (isClosed) return;
    emit(
      state.copyWith(
        busy: false,
        notice: res.isRight
            ? OrderNoticeBoxDropped(box.seq)
            : OrderNoticeFailed(res.left),
      ),
    );
    if (res.isRight) await load();
  }

  Future<void> selectBox(String boxId) async {
    await _repo.selectBox(orderId, boxId);
    await _fromCache(offline: state.view?.fromCache ?? false);
  }

  /// Пик (ADHOC-63): принят на терминале - сразу на экране, сервер подтвердит в фоне.
  Future<void> pick(PickRequest request) async {
    final res = await _repo.pick(request);
    if (isClosed) return;
    if (res.isLeft) {
      emit(state.copyWith(notice: OrderNoticeFailed(res.left)));
      return;
    }
    _localSeq++;
    emit(
      state.copyWith(
        notice: const OrderNoticeDone(unpick: false, queued: false),
      ),
    );
    await _fromCache(offline: state.view?.fromCache ?? false);
    _scheduleReload();
  }

  /// Вернуть пик.
  Future<void> unpick(PickingPick pick) =>
      _queued(_repo.unpick(orderId, pick), unpick: true);

  /// Поставить или снять «не хватает».
  Future<void> shortage(PickingLine line, {required bool set}) async {
    if (state.busy) return;
    emit(state.copyWith(busy: true));
    final res = await _repo.shortage(orderId, line.id, shortage: set);
    if (isClosed) return;
    emit(
      state.copyWith(
        busy: false,
        notice: res.isRight
            ? OrderNoticeShortage(set: set, result: res.right)
            : OrderNoticeFailed(res.left),
      ),
    );
    if (res.isRight) await _fromCache(offline: false);
  }

  Future<void> _queued(
    Future<Either<Failure, void>> action, {
    required bool unpick,
  }) async {
    final res = await action;
    if (isClosed) return;
    final OrderNotice notice;
    if (res.isRight) {
      notice = OrderNoticeDone(unpick: unpick, queued: false);
    } else if (res.left is RejectedFailure) {
      notice = OrderNoticeRejected((res.left as RejectedFailure).reason);
    } else {
      notice = OrderNoticeDone(unpick: unpick, queued: true);
    }
    emit(state.copyWith(notice: notice));
    // Принятый сервером пик - перечитать заказ: подбор и «взято» уже с ним.
    if (res.isRight) {
      await _quietReload();
    } else {
      await _fromCache();
    }
  }

  /// Взять в работу - со связью, затем заказ заново: подбор и «мой» уже с сервера.
  Future<void> _online(
    Future<Either<Failure, void>> action,
    OrderNotice ok,
  ) async {
    if (state.busy) return;
    emit(state.copyWith(busy: true));
    final res = await action;
    if (isClosed) return;
    emit(
      state.copyWith(
        busy: false,
        notice: res.isRight ? ok : OrderNoticeFailed(res.left),
      ),
    );
    await load();
  }

  /// «Завершить сборку» (P9-07) - со связью: свои пики сначала уходят из очереди.
  Future<void> complete() async {
    if (state.busy) return;
    emit(state.copyWith(busy: true));
    final res = await _repo.complete(orderId);
    if (isClosed) return;
    emit(
      state.copyWith(
        busy: false,
        notice: res.isRight
            ? OrderNoticeCompleted(res.right)
            : OrderNoticeFailed(res.left),
      ),
    );
    if (res.isLeft) await load();
  }

  void clearNotice() => emit(state.copyWith(notice: null));

  @override
  Future<void> close() async {
    _reloadTimer?.cancel();
    await _queue?.cancel();
    await _rejected?.cancel();
    return super.close();
  }
}
