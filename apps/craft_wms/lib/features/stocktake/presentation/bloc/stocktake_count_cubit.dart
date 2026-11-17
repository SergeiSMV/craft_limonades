import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:injectable/injectable.dart';

import '../../../../core/error/failure.dart';
import '../../domain/stocktake_count.dart';
import '../../domain/stocktake_models.dart';
import '../../domain/stocktake_repository.dart';

part 'stocktake_count_cubit.freezed.dart';

/// Итог подсчёта ячейки: проведён, ушёл в очередь, отклонён.
enum CountOutcome { posted, queued, rejected }

/// Подсказка по результату скана - показывается один раз.
enum CountNotice {
  /// Короб уже отмечен найденным.
  boxAgain,

  /// Найден короб не по учёту ячейки - сервер перенесёт его сюда.
  boxForeign,

  /// Марка уже отсканирована в этом подсчёте.
  markAgain,

  /// Маркируемый товар считается только сканом марок.
  scanMark,
}

/// Сколько последних действий можно отменить - как во «Вводе остатков».
const kCountUndoDepth = 10;

/// Состояние подсчёта ячейки (P10-04): насчитанное, отмена, итог отправки.
@freezed
abstract class StocktakeCountState with _$StocktakeCountState {
  const factory StocktakeCountState({
    required StocktakeCount count,

    /// Прежние состояния подсчёта для «Отменить», свежее - последним.
    @Default(<StocktakeCount>[]) List<StocktakeCount> history,
    CountNotice? notice,
    @Default(false) bool submitting,
    CountOutcome? outcome,
    String? rejectReason,
  }) = _StocktakeCountState;
}

/// Подсчёт ячейки пересчёта (P10-04): слепой счёт - позиции снимка без количеств.
///
/// Что: короба отмечаются найденными сканом ярлыка или этикетки ЧЗ; россыпь копится по
/// позиции (товар · партия · склад) - количеством из диалога или марками; «Ячейка посчитана»
/// отправляет факт операцией очереди.
/// Зачем черновик: подсчёт после скана ячейки идёт без связи и может длиться долго - выход с
/// экрана, перезапуск, разряд не должны терять насчитанное. Черновик от прежнего снимка (ячейку
/// сбили и начали заново) не подхватывается: насчитанное относится к другому снимку.
/// Решения «что это за код» принимает экран - у него справочники и снимок склада; кубит
/// только складывает насчитанное.
@injectable
class StocktakeCountCubit extends Cubit<StocktakeCountState> {
  StocktakeCountCubit(this._repo, @factoryParam StocktakeCellView view)
    : super(StocktakeCountState(count: StocktakeCount(view: view)));

  final StocktakeRepository _repo;

  StocktakeCount get count => state.count;

  /// Подхватить черновик того же снимка.
  Future<void> restore() async {
    final draft = await _repo.loadDraft(count.cell.id);
    if (draft == null || isClosed) return;
    final saved = StocktakeCount.fromJson(draft);
    if (saved.cell.startedAt != count.cell.startedAt) return;
    emit(state.copyWith(count: saved.copyWith(view: count.view)));
  }

  /// Записать новое состояние подсчёта: прежнее - в историю отмены, слепок - в черновик.
  void _apply(StocktakeCount next, {CountNotice? notice}) {
    final history = [...state.history, count];
    emit(
      state.copyWith(
        count: next,
        history: history.length > kCountUndoDepth
            ? history.sublist(history.length - kCountUndoDepth)
            : history,
        notice: notice,
      ),
    );
    _repo.saveDraft(next.cell.id, next.toJson());
  }

  /// Короб найден - сканом ярлыка или этикетки ЧЗ. Короба нет в снимке - он учётный из другого
  /// места (экран уже проверил, что WMS его знает): сервер перенесёт его сюда.
  void foundBox(String loadUnitId, {String? czCode}) {
    if (count.boxFound(loadUnitId)) {
      emit(state.copyWith(notice: CountNotice.boxAgain));
      return;
    }
    final inSnapshot = count.boxPositions.any(
      (p) => p.loadUnitId!.toLowerCase() == loadUnitId.toLowerCase(),
    );
    _apply(
      count.copyWith(
        boxes: [
          ...count.boxes,
          CountBox(
            loadUnitId: loadUnitId.toLowerCase(),
            czCode: czCode,
            foreign: !inSnapshot,
          ),
        ],
      ),
      notice: inSnapshot ? null : CountNotice.boxForeign,
    );
  }

  /// Добавить насчитанное количество позиции россыпи - к уже насчитанному.
  void addQty({
    required StocktakeGood good,
    required String productionDate,
    String? internalWarehouseId,
    required double qty,
  }) {
    if (qty <= 0) return;
    _apply(
      count.copyWith(
        lines: _merge(good, productionDate, internalWarehouseId, (l) {
          return l.copyWith(qty: l.qty + qty);
        }),
      ),
    );
  }

  /// Найденные марки позиции: количество - их число. Уже отсканированные - подсказка.
  void addMarks({
    required StocktakeGood good,
    required String productionDate,
    String? internalWarehouseId,
    required List<String> marks,
  }) {
    final fresh = [
      for (final m in marks)
        if (!count.hasMark(m)) m,
    ];
    if (fresh.isEmpty) {
      emit(state.copyWith(notice: CountNotice.markAgain));
      return;
    }
    _apply(
      count.copyWith(
        lines: _merge(good, productionDate, internalWarehouseId, (l) {
          final all = [...l.marks, ...fresh];
          return l.copyWith(marks: all, qty: all.length.toDouble());
        }),
      ),
    );
  }

  /// Насчитанное позиции, обновлённое [update]; позиции ещё нет - она заводится с нулём.
  List<CountLine> _merge(
    StocktakeGood good,
    String date,
    String? warehouseId,
    CountLine Function(CountLine) update,
  ) {
    final i = count.lines.indexWhere(
      (l) => l.samePosition(good.id, date, warehouseId),
    );
    if (i < 0) {
      return [
        ...count.lines,
        update(
          CountLine(
            good: good,
            productionDate: date,
            internalWarehouseId: warehouseId,
            qty: 0,
          ),
        ),
      ];
    }
    return [...count.lines]..[i] = update(count.lines[i]);
  }

  /// Исправить насчитанное позиции без марок: количество и партию. Сменилась партия - это уже
  /// другая позиция: насчитанное переезжает к ней (одним действием для «Отменить»).
  void editLine(
    CountLine line, {
    required String productionDate,
    required double qty,
  }) {
    if (line.marks.isNotEmpty || qty < 0) return;
    final rest = [...count.lines]..remove(line);
    final i = rest.indexWhere(
      (l) => l.samePosition(
        line.good.id,
        productionDate,
        line.internalWarehouseId,
      ),
    );
    final edited = line.copyWith(productionDate: productionDate, qty: qty);
    _apply(
      count.copyWith(
        lines: i < 0
            ? [...rest, edited]
            : ([...rest]..[i] = rest[i].copyWith(qty: rest[i].qty + qty)),
      ),
    );
  }

  /// Убрать насчитанное позиции (с марками - тоже).
  void removeLine(CountLine line) =>
      _apply(count.copyWith(lines: [...count.lines]..remove(line)));

  /// Снять отметку «найден» с короба.
  void removeBox(CountBox box) =>
      _apply(count.copyWith(boxes: [...count.boxes]..remove(box)));

  /// Отменить последнее действие.
  void undo() {
    if (state.history.isEmpty) return;
    final prev = state.history.last;
    emit(
      state.copyWith(
        count: prev,
        history: state.history.sublist(0, state.history.length - 1),
      ),
    );
    _repo.saveDraft(prev.cell.id, prev.toJson());
  }

  /// Подсказка показана.
  void clearNotice() => emit(state.copyWith(notice: null));

  /// Подсказать: маркируемый товар - сканом марок.
  void hintScanMark() => emit(state.copyWith(notice: CountNotice.scanMark));

  /// «Ячейка посчитана»: факт уходит операцией очереди. Подтверждение недостачи - за экраном.
  Future<void> submit() async {
    if (state.submitting || state.outcome != null) return;
    emit(state.copyWith(submitting: true));
    final res = await _repo.submit(count.cell.id, count.payload());
    if (isClosed) return;
    emit(
      state.copyWith(
        submitting: false,
        outcome: res.isRight
            ? CountOutcome.posted
            : res.left is RejectedFailure
            ? CountOutcome.rejected
            : CountOutcome.queued,
        rejectReason: res.isLeft && res.left is RejectedFailure
            ? (res.left as RejectedFailure).reason
            : null,
      ),
    );
  }
}
