import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:injectable/injectable.dart';

import '../../../../core/error/failure.dart';
import '../../../../core/load_unit/load_unit_id_generator.dart';
import '../../../tasks/data/tasks_models.dart';
import '../../domain/supplier_return_repository.dart';

part 'supplier_return_cubit.freezed.dart';

/// Итог сеанса отгрузки: проведён, ушёл в очередь, отклонён.
enum ReturnOutcome { posted, queued, rejected }

/// Подсказка по результату скана — показывается один раз.
enum ReturnNotice {
  /// Короба или товара нет среди неотгруженных позиций задания.
  notInTask,

  /// Короба нет среди позиций: товар из части короба при пометке вынут в россыпь ячейки —
  /// сканировать надо ячейку.
  boxNotInTask,

  /// Позиция уже отмечена.
  alreadyChecked,

  /// В отсканированной ячейке нет позиций возврата.
  cellNotInTask,

  /// Товар есть в задании, но его ячейка не отсканирована: [SupplierReturnState.noticeCell].
  needCell,
}

/// Состояние сеанса отгрузки возврата поставщику (ADHOC-31).
///
/// [marked] — отмеченные позиции (проблемы-основания); [cell] — последняя отсканированная
/// ячейка: позиции в ней активны, остальные серые — товар отмечается только там, где лежит.
@freezed
abstract class SupplierReturnState with _$SupplierReturnState {
  const factory SupplierReturnState({
    required WarehouseTask task,
    required String shipmentId,
    @Default(<String>{}) Set<String> marked,
    String? cell,
    ReturnNotice? notice,

    /// Ячейка для подсказки «отсканируйте ячейку …».
    String? noticeCell,
    @Default(false) bool submitting,
    ReturnOutcome? outcome,
    String? rejectReason,
  }) = _SupplierReturnState;

  const SupplierReturnState._();

  /// Неотгруженные позиции задания — то, что отгружает сеанс.
  List<TaskItem> get open => [
    for (final it in task.items)
      if (!it.placed && it.problemId != null) it,
  ];

  /// Позиция активна: отмечена или её ячейка отсканирована. Серую отметить нельзя — так
  /// подтверждается, что товар взят из нужного места, а не по одному штрихкоду.
  bool isActive(TaskItem it) =>
      marked.contains(it.problemId) ||
      (cell != null && it.cell.toLowerCase() == cell!.toLowerCase());

  /// Все позиции отмечены: задание отгружается только целиком.
  bool get complete =>
      open.isNotEmpty && open.every((it) => marked.contains(it.problemId));
}

/// Сеанс отгрузки возврата (ADHOC-31): отметить позиции и отгрузить задание целиком одной
/// операцией очереди.
///
/// Место подтверждается сканом: короб — его ярлыком, товар — ячейкой, после которой позиции
/// этой ячейки активны и отмечаются штрихкодом товара или касанием. Штрихкод без ячейки
/// позицию не отмечает: кладовщик иначе брал бы товар откуда удобно.
@injectable
class SupplierReturnCubit extends Cubit<SupplierReturnState> {
  SupplierReturnCubit(
    this._repo,
    LoadUnitIdGenerator ids,
    @factoryParam WarehouseTask task,
  ) : super(SupplierReturnState(task: task, shipmentId: ids.newId()));

  final SupplierReturnRepository _repo;

  /// Скан ярлыка короба: отметить позицию-короб.
  void scanBox(String loadUnitId) {
    final id = loadUnitId.toLowerCase();
    final boxes = state.open.where((it) => it.loadUnitId?.toLowerCase() == id);
    if (boxes.isEmpty) {
      emit(state.copyWith(notice: ReturnNotice.boxNotInTask));
      return;
    }
    _check(boxes);
  }

  /// Скан ячейки: её позиции становятся активными. Ячейка без позиций — подсказка.
  void scanCell(String address) {
    final a = address.toLowerCase();
    if (!state.open.any((it) => it.cell.toLowerCase() == a)) {
      emit(state.copyWith(notice: ReturnNotice.cellNotInTask));
      return;
    }
    emit(state.copyWith(cell: address));
  }

  /// Скан товара: отметить его позицию в отсканированной ячейке. Ячейка не та или не
  /// отсканирована — подсказка, какую сканировать.
  void scanGood(String goodId) {
    final candidates = state.open.where((it) => it.good?.id == goodId).toList();
    if (candidates.isEmpty) {
      emit(state.copyWith(notice: ReturnNotice.notInTask));
      return;
    }
    final here = candidates.where(
      (it) =>
          state.cell != null &&
          it.cell.toLowerCase() == state.cell!.toLowerCase(),
    );
    if (here.isEmpty) {
      final waiting = candidates.where(
        (it) => !state.marked.contains(it.problemId),
      );
      emit(
        state.copyWith(
          notice: waiting.isEmpty
              ? ReturnNotice.alreadyChecked
              : ReturnNotice.needCell,
          noticeCell: (waiting.isEmpty ? candidates : waiting).first.cell,
        ),
      );
      return;
    }
    _check(here);
  }

  /// Касание позиции: активную — отметить или снять отметку (ярлык затёрт, штрихкода нет);
  /// серую — подсказка, какую ячейку сканировать.
  void toggle(TaskItem item) {
    final id = item.problemId;
    if (id == null) return;
    if (!state.isActive(item)) {
      emit(
        state.copyWith(notice: ReturnNotice.needCell, noticeCell: item.cell),
      );
      return;
    }
    final next = {...state.marked};
    if (!next.remove(id)) next.add(id);
    emit(state.copyWith(marked: next));
  }

  void _check(Iterable<TaskItem> candidates) {
    if (candidates.isEmpty) {
      emit(state.copyWith(notice: ReturnNotice.notInTask));
      return;
    }
    final free = candidates.where((it) => !state.marked.contains(it.problemId));
    if (free.isEmpty) {
      emit(state.copyWith(notice: ReturnNotice.alreadyChecked));
      return;
    }
    emit(state.copyWith(marked: {...state.marked, free.first.problemId!}));
  }

  /// Подсказка показана.
  void clearNotice() => emit(state.copyWith(notice: null, noticeCell: null));

  /// Тело операции `return_submit` — формат эталона `testdata/return_submit.json`. Позиции —
  /// в порядке задания.
  static Map<String, dynamic> payload(SupplierReturnState s) => {
    'shipment_id': s.shipmentId,
    'task_id': s.task.id,
    'warehouse_id': s.task.warehouseId,
    'problem_ids': [
      for (final it in s.open)
        if (s.marked.contains(it.problemId)) it.problemId,
    ],
  };

  /// «Отгружено»: только когда отмечены все позиции.
  Future<void> submit() async {
    if (!state.complete || state.submitting) return;
    emit(state.copyWith(submitting: true));
    final res = await _repo.submit(
      payload: payload(state),
      taskId: state.task.id,
      problemIds: state.marked,
    );
    if (isClosed) return;
    emit(
      state.copyWith(
        submitting: false,
        outcome: res.isRight
            ? ReturnOutcome.posted
            : res.left is RejectedFailure
            ? ReturnOutcome.rejected
            : ReturnOutcome.queued,
        rejectReason: res.isLeft && res.left is RejectedFailure
            ? (res.left as RejectedFailure).reason
            : null,
      ),
    );
  }
}
