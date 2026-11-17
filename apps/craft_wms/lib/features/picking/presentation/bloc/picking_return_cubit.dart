import 'dart:math' as math;

import 'package:either_dart/either.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:injectable/injectable.dart';

import '../../../../core/error/failure.dart';
import '../../../stock/domain/catalog_models.dart';
import '../../domain/picking_return.dart';
import '../../domain/picking_return_repository.dart';

part 'picking_return_cubit.freezed.dart';

/// Подсказка экрана возврата - показывается один раз.
sealed class ReturnNotice {
  const ReturnNotice();
}

/// Запрос к серверу не удался - причина [failure].
final class ReturnNoticeFailed extends ReturnNotice {
  const ReturnNoticeFailed(this.failure);
  final Failure failure;
}

/// Сервер отказал по существу: текст [reason].
final class ReturnNoticeRejected extends ReturnNotice {
  const ReturnNoticeRejected(this.reason);
  final String reason;
}

/// Вернули [qty] в ячейку [cell].
final class ReturnNoticeReturned extends ReturnNotice {
  const ReturnNoticeReturned(this.qty, this.cell);
  final double qty;
  final String cell;
}

/// Без связи: возврат в очереди.
final class ReturnNoticeQueued extends ReturnNotice {
  const ReturnNoticeQueued();
}

/// Взятое удалённого заказа вернули в источник.
final class ReturnNoticeUnpicked extends ReturnNotice {
  const ReturnNoticeUnpicked();
}

/// Возвращать больше нечего - экран закрывается.
final class ReturnNoticeDone extends ReturnNotice {
  const ReturnNoticeDone();
}

/// Подсказки скана.
enum ReturnHint {
  /// Короб не из заказа или в нём нечего возвращать.
  boxForeign,

  /// Сначала сканировать короб позиции.
  boxFirst,

  /// Марка не из выбранной позиции.
  markForeign,

  /// Марка уже отсканирована.
  markAgain,

  /// Сначала выбрать позицию.
  chooseFirst,

  /// Ячейка приёмки или отгрузки - сюда не возвращают.
  cellDenied,

  /// Скан не источника открытого пика.
  sourceMismatch,
}

/// Подсказка скана [hint]; [seq] - номер короба, [source] - где брали.
final class ReturnNoticeHint extends ReturnNotice {
  const ReturnNoticeHint(this.hint, {this.seq, this.source});
  final ReturnHint hint;
  final int? seq;
  final String? source;
}

enum PickingReturnStatus { loading, loaded, error }

/// Экран «вернуть на места» (P9-07-1).
@freezed
abstract class PickingReturnState with _$PickingReturnState {
  const factory PickingReturnState({
    @Default(PickingReturnStatus.loading) PickingReturnStatus status,
    PickingReturnView? view,
    Failure? failure,

    /// Отсканированный короб отгрузки: из него выбирают позицию.
    String? boxId,

    /// Выбранная позиция (пик).
    String? pickId,

    /// Сколько вернуть из выбранной немаркируемой позиции.
    double? qty,

    /// Отсканированные марки выбранной маркируемой позиции.
    @Default(<String>[]) List<String> marks,

    /// Возвраты в очереди без связи: пик → штук. Вычитаются из показанного, пока сервер их
    /// не учтёт.
    @Default(<String, double>{}) Map<String, double> pending,
    @Default(false) bool busy,
    ReturnNotice? notice,
  }) = _PickingReturnState;

  const PickingReturnState._();

  /// Выбранная позиция.
  PickingReturnPick? get selected =>
      view?.picks.where((p) => p.pickId == pickId).firstOrNull;

  /// Сколько ещё в очереди по пикам строки [lineId].
  double pendingOfLine(String lineId) => (view?.picks ?? const [])
      .where((p) => p.lineId == lineId)
      .fold(0, (sum, p) => sum + (pending[p.pickId] ?? 0));

  /// Сколько можно вернуть из пика [p]: не больше, чем в нём, и чем осталось по строке.
  double available(PickingReturnPick p) => math.max(
    0,
    math.min(
      p.qty - (pending[p.pickId] ?? 0),
      (view?.lineLeft(p.lineId) ?? 0) - pendingOfLine(p.lineId),
    ),
  );

  /// Позиции, из которых ещё есть что вернуть.
  List<PickingReturnPick> get open =>
      (view?.picks ?? const []).where((p) => available(p) > 0).toList();

  /// Сколько всего осталось вернуть с учётом очереди.
  double get left => math.max(
    0,
    (view?.left ?? 0) - pending.values.fold(0.0, (a, b) => a + b),
  );

  /// Сколько возвращают сейчас: марками или введённым количеством.
  double get takingQty {
    final p = selected;
    if (p == null) return 0;
    return p.czMarked ? marks.length.toDouble() : (qty ?? 0);
  }
}

/// Возврат на места по заказу после правки реестра (P9-07-1).
///
/// Что: перенесённое в короб отгрузки - сканом короба, выбором позиции, количеством (у
/// маркируемого - сканом марок) и сканом ячейки хранения, куда кладут; взятое удалённого заказа,
/// ещё у источника, - выбором позиции и сканом её ячейки или короба хранения. Каждый возврат -
/// своя операция очереди: работает без связи, а что вернуть, пересчитывает сервер.
@injectable
class PickingReturnCubit extends Cubit<PickingReturnState> {
  PickingReturnCubit(this._repo, @factoryParam this.orderId)
    : super(const PickingReturnState());

  final PickingReturnRepository _repo;
  final String orderId;

  /// Загрузить, что вернуть. Учтённое сервером снимается из очереди показа.
  Future<void> load() async {
    final res = await _repo.view(orderId);
    if (isClosed) return;
    res.fold(
      (f) => emit(
        state.copyWith(
          status: state.view == null ? PickingReturnStatus.error : state.status,
          failure: f,
          notice: state.view == null ? null : ReturnNoticeFailed(f),
        ),
      ),
      (v) {
        emit(
          state.copyWith(
            status: PickingReturnStatus.loaded,
            view: v,
            failure: null,
            pending: const {},
          ),
        );
        if (v.left <= 0) emit(state.copyWith(notice: const ReturnNoticeDone()));
      },
    );
  }

  /// Скан ГЕ: короб отгрузки - выбрать его; короб хранения - источник выбранной открытой
  /// позиции.
  Future<void> scanLoadUnit(String loadUnitId) async {
    final sel = state.selected;
    if (sel != null && !sel.moved) {
      if (sel.sourceLoadUnitId == loadUnitId) return _unpick(sel);
      _hint(ReturnHint.sourceMismatch, source: sel.sourceCell);
      return;
    }
    final inBox = state.open.where((p) => p.moved && p.boxId == loadUnitId);
    if (inBox.isEmpty) {
      _hint(ReturnHint.boxForeign);
      return;
    }
    emit(state.copyWith(boxId: loadUnitId, pickId: null, qty: null, marks: []));
  }

  /// Выбрать позицию. Из короба отгрузки - только после скана этого короба; [qty] -
  /// введённое количество немаркируемой.
  void select(PickingReturnPick p, {double? qty}) {
    if (p.moved && state.boxId != p.boxId) {
      _hint(ReturnHint.boxFirst, seq: p.boxSeq);
      return;
    }
    emit(state.copyWith(pickId: p.pickId, qty: qty, marks: []));
  }

  /// Снять выбор позиции.
  void clearSelection() =>
      emit(state.copyWith(pickId: null, qty: null, marks: []));

  /// Скан марки выбранной маркируемой позиции.
  void scanMark(String cis) {
    final p = state.selected;
    if (p == null || !p.czMarked) {
      _hint(ReturnHint.chooseFirst);
      return;
    }
    if (state.marks.contains(cis)) {
      _hint(ReturnHint.markAgain);
      return;
    }
    if (!p.marks.contains(cis) || state.marks.length >= state.available(p)) {
      _hint(ReturnHint.markForeign);
      return;
    }
    emit(state.copyWith(marks: [...state.marks, cis]));
  }

  /// Скан ячейки: у позиции из короба - куда кладут, у открытой - её источник.
  Future<void> scanCell(Cell cell) async {
    final p = state.selected;
    if (p == null || state.busy) {
      _hint(ReturnHint.chooseFirst);
      return;
    }
    if (!p.moved) {
      if (p.sourceLoadUnitId == null && p.sourceCellId == cell.id) {
        return _unpick(p);
      }
      _hint(ReturnHint.sourceMismatch, source: p.sourceCell);
      return;
    }
    if (cell.isDefault) {
      _hint(ReturnHint.cellDenied);
      return;
    }
    final qty = state.takingQty;
    if (qty <= 0) {
      _hint(ReturnHint.chooseFirst);
      return;
    }
    emit(state.copyWith(busy: true));
    final res = await _repo.putBack(
      p,
      qty: qty,
      cellId: cell.id,
      marks: state.marks,
    );
    if (isClosed) return;
    await _settle(res, p, qty, ReturnNoticeReturned(qty, cell.address));
  }

  Future<void> _unpick(PickingReturnPick p) async {
    if (state.busy) return;
    emit(state.copyWith(busy: true));
    final res = await _repo.unpick(p);
    if (isClosed) return;
    await _settle(res, p, p.qty, const ReturnNoticeUnpicked());
  }

  /// Итог операции: принята - перечитать, что вернуть; отказ - показать причину; без связи -
  /// отметить в очереди.
  Future<void> _settle(
    Either<Failure, void> res,
    PickingReturnPick p,
    double qty,
    ReturnNotice ok,
  ) async {
    final cleared = state.copyWith(
      busy: false,
      pickId: null,
      qty: null,
      marks: const [],
    );
    if (res.isRight) {
      emit(cleared.copyWith(notice: ok));
      await load();
      return;
    }
    final f = res.left;
    if (f is RejectedFailure) {
      emit(state.copyWith(busy: false, notice: ReturnNoticeRejected(f.reason)));
      return;
    }
    emit(
      cleared.copyWith(
        pending: {
          ...state.pending,
          p.pickId: (state.pending[p.pickId] ?? 0) + qty,
        },
        notice: const ReturnNoticeQueued(),
      ),
    );
  }

  void _hint(ReturnHint hint, {int? seq, String? source}) => emit(
    state.copyWith(
      notice: ReturnNoticeHint(hint, seq: seq, source: source),
    ),
  );

  /// Подсказку показали.
  void clearNotice() => emit(state.copyWith(notice: null));
}
