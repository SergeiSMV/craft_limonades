import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:injectable/injectable.dart';

import '../../../../core/error/failure.dart';
import '../../../../core/load_unit/load_unit_id_generator.dart';
import '../../../contents/domain/contents_entities.dart';
import '../../../stock/data/catalog_models.dart';
import '../../domain/movement_models.dart';
import '../../domain/movement_repository.dart';
import 'movement_state.dart';

/// Cubit перемещения на ТСД (P6-04).
///
/// Решения о потоке — здесь, без сети и базы: экран находит короб, ячейку и товар и передаёт
/// найденное, cubit решает, что это значит в текущем шаге. Правила (решения 2026-10-13):
/// - скан короба или ячейки с пустыми руками — это источник;
/// - в руках короб: ячейка — короб едет целиком, товар — берётся из короба;
/// - в руках товар: ячейка — кладём россыпью, короб — кладём в короб;
/// - ячейка приёмки и ячейка другого склада не годятся ни источником, ни приёмником.
@injectable
class MovementCubit extends Cubit<MovementState> {
  MovementCubit(this._repo, this._ids) : super(const MovementState());

  final MovementRepository _repo;
  final LoadUnitIdGenerator _ids;

  /// Очередь записей черновика: два быстрых изменения подряд иначе легли бы в базу в обратном
  /// порядке (приём приёмки и размещения).
  Future<void> _writes = Future<void>.value();

  //* --- черновик --- *//

  /// Открыть сеанс: продолжить незавершённый или начать новый. Взятое в руки в черновик не
  /// пишется: после перезапуска его берут заново — за это время оно могло и переехать.
  Future<void> init() async {
    final draft = await _repo.loadDraft();
    if (draft == null) {
      emit(state.copyWith(movementId: _ids.newId()));
      return;
    }
    emit(
      state.copyWith(
        movementId: draft['movement_id'] as String? ?? _ids.newId(),
        warehouseId: draft['warehouse_id'] as String?,
        lines: [
          for (final e in draft['lines'] as List<dynamic>? ?? const [])
            MoveLine.fromJson(e as Map<String, dynamic>),
        ],
      ),
    );
  }

  /// Сохранение черновика повешено на [emit]: метод, добавленный позже, про сохранение забыл
  /// бы, а один перехват на все изменения забыть невозможно. Пустой сеанс черновиком не
  /// считается — иначе плитка помечалась бы от одного входа на экран.
  @override
  void emit(MovementState state) {
    super.emit(state);
    if (state.movementId == null) return;
    final keep = state.outcome == null && state.lines.isNotEmpty;
    final snapshot = keep
        ? {
            'movement_id': state.movementId,
            'warehouse_id': state.warehouseId,
            'lines': state.lines.map((l) => l.toJson()).toList(),
          }
        : null;
    _writes = _writes
        .then(
          (_) =>
              snapshot == null ? _repo.clearDraft() : _repo.saveDraft(snapshot),
        )
        .catchError((_) {});
  }

  /// Дождаться записи черновика — нужно только тестам.
  @visibleForTesting
  Future<void> get draftWrites => _writes;

  //* --- скан короба и ячейки --- *//

  /// Отсканирован или выбран вручную ([manual]) короб. [box] — его карточка (с сервера или
  /// из снимка с очередью поверх), [cell] — ячейка, где он лежит сейчас с учётом этого
  /// сеанса; `null` — не размещён.
  ///
  /// В руках товар — короб становится приёмником. Иначе короб берётся в руки источником.
  void onBox(LoadUnitView box, Cell? cell, {bool manual = false}) {
    if (cell == null || !box.live) {
      emit(state.copyWith(notice: const MoveNotice.boxEmpty()));
      return;
    }
    if (!_cellAllowed(cell)) return;
    final place = MovePlace(
      cellId: cell.id,
      cellAddress: cell.address,
      loadUnitId: box.id,
    );
    switch (state.hold) {
      case HoldGoods():
        _put(place, cell);
      case HoldSource(place: final held) when held.isBox:
        emit(state.copyWith(notice: const MoveNotice.boxIntoBox()));
      default:
        emit(
          state.copyWith(
            hold: MoveHold.source(
              place: place,
              contents: box.lines,
              manual: manual,
            ),
            warehouseId: state.warehouseId ?? cell.warehouseId,
            notice: null,
          ),
        );
    }
  }

  /// Отсканирована ячейка. [loose] — её россыпь (нужна, только если ячейка становится
  /// источником).
  ///
  /// В руках короб — он едет сюда целиком. В руках товар — ложится сюда россыпью. Иначе
  /// россыпь ячейки становится источником.
  void onCell(Cell cell, {List<ContentLine> loose = const []}) {
    if (!_cellAllowed(cell)) return;
    final place = MovePlace(cellId: cell.id, cellAddress: cell.address);
    switch (state.hold) {
      case HoldGoods():
        _put(place, cell);
      case HoldSource(place: final held) when held.isBox:
        _moveBox(held, place, cell);
      default:
        final source = MoveHold.source(place: place, contents: loose);
        if (state.candidates(source as HoldSource).isEmpty) {
          emit(state.copyWith(notice: const MoveNotice.noLoose()));
          return;
        }
        emit(
          state.copyWith(
            hold: source,
            warehouseId: state.warehouseId ?? cell.warehouseId,
            notice: null,
          ),
        );
    }
  }

  /// Ячейка годится в дело: не ячейка приёмки (из неё и в неё двигают заданием на
  /// размещение) и того же склада, что сеанс.
  bool _cellAllowed(Cell cell) {
    if (cell.isDefault) {
      emit(state.copyWith(notice: const MoveNotice.receivingCell()));
      return false;
    }
    final wh = state.warehouseId;
    if (wh != null && cell.warehouseId != wh) {
      emit(state.copyWith(notice: const MoveNotice.foreignCell()));
      return false;
    }
    return true;
  }

  /// Короб целиком — в ячейку. Строка сеанса; руки свободны.
  void _moveBox(MovePlace box, MovePlace to, Cell cell) {
    if (box.cellId == to.cellId) {
      emit(state.copyWith(notice: const MoveNotice.sameCell()));
      return;
    }
    emit(
      state.copyWith(
        lines: [
          ...state.lines,
          MoveLine(loadUnitId: box.loadUnitId, from: box, to: to),
        ],
        hold: null,
        notice: MoveNotice.moved(cell.address),
      ),
    );
  }

  //* --- товар --- *//

  /// Что можно взять из источника в руках; [goodId] — только этот товар. Пусто — источника
  /// нет или брать нечего.
  List<(ContentLine, double)> candidates({String? goodId}) =>
      switch (state.hold) {
        final HoldSource s => state.candidates(s, goodId: goodId),
        _ => const [],
      };

  /// Отсканирован товар, а взять его неоткуда или он уже в руках — подсказка.
  void goodWithoutSource() => emit(
    state.copyWith(
      notice: state.hold is HoldGoods
          ? const MoveNotice.putFirst()
          : const MoveNotice.sourceFirst(),
    ),
  );

  /// Товара нет в источнике.
  void goodNotInSource() =>
      emit(state.copyWith(notice: const MoveNotice.notInSource()));

  /// Взять товар партии [line] количеством [qty] — не больше, чем есть в источнике.
  void takeGoods(ContentLine line, double qty) {
    final hold = state.hold;
    if (hold is! HoldSource) return;
    final left = state.available(hold, line.goodId, line.productionDate);
    if (qty <= 0 || qty > left) return;
    emit(
      state.copyWith(
        hold: MoveHold.goods(
          good: MoveGood(
            id: line.goodId,
            name: line.goodName ?? '',
            code: line.goodCode,
            uom: line.uom ?? '',
          ),
          productionDate: line.productionDate,
          qty: qty,
          from: hold.place,
        ),
        notice: null,
      ),
    );
  }

  /// Положить взятый товар в [to]. Тот же товар той же партии тем же путём — одна строка
  /// с суммой.
  void _put(MovePlace to, Cell cell) {
    final g = state.hold;
    if (g is! HoldGoods) return;
    if (g.from.samePlace(to)) {
      emit(state.copyWith(notice: const MoveNotice.samePlace()));
      return;
    }
    final lines = List<MoveLine>.from(state.lines);
    final same = lines.indexWhere(
      (l) =>
          !l.isWholeBox &&
          l.good?.id == g.good.id &&
          l.productionDate == g.productionDate &&
          l.from.samePlace(g.from) &&
          l.to.samePlace(to),
    );
    if (same >= 0) {
      lines[same] = lines[same].copyWith(qty: (lines[same].qty ?? 0) + g.qty);
    } else {
      lines.add(
        MoveLine(
          good: g.good,
          productionDate: g.productionDate,
          qty: g.qty,
          from: g.from,
          to: to,
        ),
      );
    }
    emit(
      state.copyWith(
        lines: lines,
        hold: null,
        notice: MoveNotice.moved(cell.address),
      ),
    );
  }

  //* --- прочее --- *//

  /// Ярлык короба, которого нет: на сервере — недействителен; без связи и в снимке — не
  /// проверить.
  void boxNotFound({required bool offline}) => emit(
    state.copyWith(
      notice: offline
          ? const MoveNotice.boxUnknownOffline()
          : const MoveNotice.labelInvalid(),
    ),
  );

  /// Положить обратно — передумал.
  void dropHold() => emit(state.copyWith(hold: null, notice: null));

  /// Убрать строку сеанса — перемещено не туда.
  void removeLine(MoveLine line) {
    final lines = List<MoveLine>.from(state.lines);
    if (!lines.remove(line)) return;
    emit(state.copyWith(lines: lines, notice: null));
  }

  /// Подсказка показана.
  void clearNotice() => emit(state.copyWith(notice: null));

  //* --- завершение --- *//

  /// Завершить сеанс: поставить в очередь одной операцией и попробовать отправить.
  Future<void> submit() async {
    if (!state.canSubmit) return;
    emit(state.copyWith(busy: true, notice: null));
    final res = await _repo.submit(payload(state));
    final s = state.copyWith(busy: false);
    emit(
      res.fold(
        (f) => f is RejectedFailure
            ? s.copyWith(outcome: MoveOutcome.rejected, rejectReason: f.reason)
            : s.copyWith(outcome: MoveOutcome.queued),
        (_) => s.copyWith(outcome: MoveOutcome.posted),
      ),
    );
  }

  /// Тело операции `movement_submit` — формат эталона `testdata/movement_submit.json`.
  ///
  /// У короба ячейку не шлём: сервер берёт её из места короба. Дата партии — в транспортном
  /// виде DD-MM-YYYY.
  @visibleForTesting
  static Map<String, dynamic> payload(MovementState s) => {
    'movement_id': s.movementId,
    'movement_kind': 'move',
    'warehouse_id': s.warehouseId,
    'lines': [
      for (final l in s.lines)
        l.isWholeBox
            ? {'load_unit_id': l.loadUnitId, 'to_cell_id': l.to.cellId}
            : {
                'good_id': l.good!.id,
                'production_date': l.productionDate,
                'qty': l.qty,
                if (l.from.isBox)
                  'from_load_unit_id': l.from.loadUnitId
                else
                  'from_cell_id': l.from.cellId,
                if (l.to.isBox)
                  'to_load_unit_id': l.to.loadUnitId
                else
                  'to_cell_id': l.to.cellId,
              },
    ],
  };
}
