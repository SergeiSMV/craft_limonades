import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:injectable/injectable.dart';

import '../../../../core/error/failure.dart';
import '../../../../core/load_unit/load_unit_id_generator.dart';
import '../../../tasks/domain/tasks_models.dart';
import '../../domain/supplier_return_repository.dart';

part 'supplier_return_cubit.freezed.dart';

/// Итог сеанса отгрузки: проведён, ушёл в очередь, отклонён.
enum ReturnOutcome { posted, queued, rejected }

/// Подсказка по результату скана - показывается один раз.
enum ReturnNotice {
  /// Короба или товара нет среди неотгруженных позиций задания.
  notInTask,

  /// Короба нет среди позиций: товар из части короба при пометке вынут в россыпь ячейки -
  /// сканировать надо ячейку.
  boxNotInTask,

  /// Позиция уже отмечена.
  alreadyChecked,

  /// В отсканированной ячейке нет позиций возврата.
  cellNotInTask,

  /// Товар есть в задании, но его ячейка не отсканирована: [SupplierReturnState.noticeCell].
  needCell,

  /// Позиция маркируемого товара отмечается только сканом каждой марки (CZ-06, долг 30).
  scanMark,
}

/// Состояние сеанса отгрузки возврата поставщику (ADHOC-31).
///
/// [marked] - отмеченные позиции (проблемы-основания); [cell] - последняя отсканированная
/// ячейка: позиции в ней активны, остальные серые - товар отмечается только там, где лежит.
@freezed
abstract class SupplierReturnState with _$SupplierReturnState {
  const factory SupplierReturnState({
    required WarehouseTask task,
    required String shipmentId,
    @Default(<String>{}) Set<String> marked,

    /// Отсканированные марки ЧЗ позиций россыпью (CZ-06, долг 30).
    @Default(<String>{}) Set<String> scannedMarks,
    String? cell,
    ReturnNotice? notice,

    /// Ячейка для подсказки «отсканируйте ячейку …».
    String? noticeCell,
    @Default(false) bool submitting,
    ReturnOutcome? outcome,
    String? rejectReason,
  }) = _SupplierReturnState;

  const SupplierReturnState._();

  /// Неотгруженные позиции задания - то, что отгружает сеанс.
  List<TaskItem> get open => [
    for (final it in task.items)
      if (!it.placed && it.problemId != null) it,
  ];

  /// Позиция активна: отмечена или её ячейка отсканирована. Серую отметить нельзя - так
  /// подтверждается, что товар взят из нужного места, а не по одному штрихкоду. Позиция с
  /// марками активна всегда: место подтверждает скан самой марки (CZ-06).
  bool isActive(TaskItem it) =>
      it.marks.isNotEmpty ||
      marked.contains(it.problemId) ||
      (cell != null && it.cell.toLowerCase() == cell!.toLowerCase());

  /// Сколько марок позиции [it] отсканировано.
  int scannedOf(TaskItem it) => it.marks.where(scannedMarks.contains).length;

  /// Все позиции отмечены: задание отгружается только целиком.
  bool get complete =>
      open.isNotEmpty && open.every((it) => marked.contains(it.problemId));
}

/// Сеанс отгрузки возврата (ADHOC-31): отметить позиции и отгрузить задание целиком одной
/// операцией очереди.
///
/// Место подтверждается сканом: короб - его ярлыком, товар - ячейкой, после которой позиции
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

  /// Скан этикетки короба ЧЗ (`00`+SSCC, CZ-06): ярлыка WMS у короба ЧЗ нет, задание знает
  /// его код.
  void scanCzBox(String czCode) {
    final boxes = state.open.where((it) => it.czCode == czCode);
    if (boxes.isEmpty) {
      emit(state.copyWith(notice: ReturnNotice.boxNotInTask));
      return;
    }
    _check(boxes);
  }

  /// Скан марки ЧЗ (CZ-06, долг 30): марка отмечается в своей позиции; отсканированы все марки
  /// позиции - позиция отмечена. Место марка подтверждает сама: она - тот самый экземпляр.
  void scanMark(String cis) {
    final item = state.open.where((it) => it.marks.contains(cis)).firstOrNull;
    if (item == null) {
      emit(state.copyWith(notice: ReturnNotice.notInTask));
      return;
    }
    if (state.scannedMarks.contains(cis)) {
      emit(state.copyWith(notice: ReturnNotice.alreadyChecked));
      return;
    }
    final scanned = {...state.scannedMarks, cis};
    final all = item.marks.every(scanned.contains);
    emit(
      state.copyWith(
        scannedMarks: scanned,
        marked: all ? {...state.marked, item.problemId!} : state.marked,
      ),
    );
  }

  /// Скан ячейки: её позиции становятся активными. Ячейка без позиций - подсказка.
  void scanCell(String address) {
    final a = address.toLowerCase();
    if (!state.open.any((it) => it.cell.toLowerCase() == a)) {
      emit(state.copyWith(notice: ReturnNotice.cellNotInTask));
      return;
    }
    emit(state.copyWith(cell: address));
  }

  /// Скан товара: отметить его позицию в отсканированной ячейке. Ячейка не та или не
  /// отсканирована - подсказка, какую сканировать.
  void scanGood(String goodId) {
    final candidates = state.open.where((it) => it.good?.id == goodId).toList();
    if (candidates.isEmpty) {
      emit(state.copyWith(notice: ReturnNotice.notInTask));
      return;
    }
    // Позиции с марками штрихкодом не отмечаются (CZ-06): какие экземпляры уехали, должно
    // быть известно.
    if (candidates.every((it) => it.marks.isNotEmpty)) {
      emit(state.copyWith(notice: ReturnNotice.scanMark));
      return;
    }
    candidates.removeWhere((it) => it.marks.isNotEmpty);
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

  /// Касание позиции: активную - отметить или снять отметку (ярлык затёрт, штрихкода нет);
  /// серую - подсказка, какую ячейку сканировать.
  void toggle(TaskItem item) {
    final id = item.problemId;
    if (id == null) return;
    if (item.marks.isNotEmpty) {
      emit(state.copyWith(notice: ReturnNotice.scanMark));
      return;
    }
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

  /// Тело операции `return_submit` - формат эталона `testdata/return_submit.json`. Позиции -
  /// в порядке задания; марки ЧЗ (CZ-06) - отмеченных позиций, только когда они есть.
  static Map<String, dynamic> payload(SupplierReturnState s) {
    final marked = [
      for (final it in s.open)
        if (s.marked.contains(it.problemId)) it,
    ];
    final marks = [
      for (final it in marked)
        for (final m in it.marks)
          if (s.scannedMarks.contains(m)) m,
    ];
    return {
      'shipment_id': s.shipmentId,
      'task_id': s.task.id,
      'warehouse_id': s.task.warehouseId,
      'problem_ids': [for (final it in marked) it.problemId],
      if (marks.isNotEmpty) 'marks': marks,
    };
  }

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
