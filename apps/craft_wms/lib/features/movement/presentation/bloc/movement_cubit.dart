import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:injectable/injectable.dart';

import '../../../../core/error/failure.dart';
import '../../../../core/load_unit/load_unit_id_generator.dart';
import '../../../../core/outbox/sent_sessions.dart';
import '../../../contents/domain/contents_entities.dart';
import '../../../stock/domain/catalog_models.dart';
import '../../domain/movement_models.dart';
import '../../domain/movement_repository.dart';
import 'movement_state.dart';

/// Cubit перемещения на ТСД (P6-04).
///
/// Решения о потоке - здесь, без сети и базы: экран находит короб, ячейку и товар и передаёт
/// найденное, cubit решает, что это значит в текущем шаге. Правила (решения 2026-10-13):
/// - скан короба или ячейки с пустыми руками - это источник;
/// - в руках короб: ячейка - короб едет целиком, товар - берётся из короба;
/// - в руках товар: ячейка - кладём россыпью, короб - кладём в короб;
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
  /// пишется: после перезапуска его берут заново - за это время оно могло и переехать.
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
        fixReason: draft['fix_reason'] as String?,
        lines: [
          for (final e in draft['lines'] as List<dynamic>? ?? const [])
            MoveLine.fromJson(e as Map<String, dynamic>),
        ],
      ),
    );
  }

  /// Сохранение черновика повешено на [emit]: метод, добавленный позже, про сохранение забыл
  /// бы, а один перехват на все изменения забыть невозможно. Пустой сеанс черновиком не
  /// считается - иначе плитка помечалась бы от одного входа на экран.
  @override
  void emit(MovementState state) {
    super.emit(state);
    if (state.movementId == null) return;
    final keep = state.outcome == null && state.lines.isNotEmpty;
    final snapshot = keep ? session(state) : null;
    _writes = _writes
        .then(
          (_) =>
              snapshot == null ? _repo.clearDraft() : _repo.saveDraft(snapshot),
        )
        .catchError((_) {});
  }

  /// Слепок сеанса - черновик и копия отправленного документа (ADHOC-41) в одном виде.
  @visibleForTesting
  static Map<String, dynamic> session(MovementState s) => {
    'movement_id': s.movementId,
    'warehouse_id': s.warehouseId,
    'lines': s.lines.map((l) => l.toJson()).toList(),
    if (s.fixReason != null) 'fix_reason': s.fixReason,
  };

  /// Дождаться записи черновика - нужно только тестам.
  @visibleForTesting
  Future<void> get draftWrites => _writes;

  //* --- скан короба и ячейки --- *//

  /// Отсканирован или выбран вручную ([manual]) короб. [box] - его карточка (с сервера или
  /// из снимка с очередью поверх), [cell] - ячейка, где он лежит сейчас с учётом этого
  /// сеанса; `null` - не размещён.
  ///
  /// В руках товар - короб становится приёмником. Иначе короб берётся в руки источником.
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
      internalWarehouseId: box.internalWarehouseId,
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

  /// Отсканирована ячейка. [loose] - её россыпь (нужна, только если ячейка становится
  /// источником).
  ///
  /// В руках короб - он едет сюда целиком. В руках товар - ложится сюда россыпью. Иначе
  /// россыпь ячейки становится источником.
  void onCell(Cell cell, {List<ContentLine> loose = const []}) {
    final asSource = switch (state.hold) {
      HoldGoods() => false,
      HoldSource(place: final held) => !held.isBox,
      _ => true,
    };
    if (!_cellAllowed(cell, labelledSource: asSource)) return;
    final place = MovePlace(cellId: cell.id, cellAddress: cell.address);
    switch (state.hold) {
      case HoldGoods():
        _put(place, cell);
      case HoldSource(place: final held) when held.isBox:
        _moveBox(held, place, cell);
      default:
        // Из ячейки приёмки - только россыпь с меткой (ADHOC-55): «Основной» разносит задание.
        final source = MoveHold.source(
          place: place,
          contents: cell.isDefault
              ? [
                  for (final l in loose)
                    if (l.internalWarehouseId != null) l,
                ]
              : loose,
        );
        if (state.candidates(source as HoldSource).isEmpty) {
          emit(
            state.copyWith(
              notice: cell.isDefault
                  ? const MoveNotice.receivingCell()
                  : const MoveNotice.noLoose(),
            ),
          );
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
  /// размещение) и того же склада, что сеанс. [labelledSource] - ячейка приёмки берётся
  /// источником россыпи с меткой склада: задание её не разносит (ADHOC-55), что именно
  /// из неё брать, решает вызывающий.
  bool _cellAllowed(Cell cell, {bool labelledSource = false}) {
    if (cell.isDefault && !labelledSource) {
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

  /// Короб целиком - в ячейку. Строка сеанса; руки свободны.
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

  /// Что можно взять из источника в руках; [goodId] - только этот товар. Пусто - источника
  /// нет или брать нечего.
  List<(ContentLine, double)> candidates({String? goodId}) =>
      switch (state.hold) {
        final HoldSource s => state.candidates(s, goodId: goodId),
        _ => const [],
      };

  /// Отсканирован товар, а взять его неоткуда или он уже в руках - подсказка.
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

  /// Взять товар партии [line] количеством [qty] - не больше, чем есть в источнике.
  void takeGoods(ContentLine line, double qty) {
    final hold = state.hold;
    if (hold is! HoldSource) return;
    final left = state.available(
      hold,
      line.goodId,
      line.productionDate,
      warehouseId: line.internalWarehouseId,
    );
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
          internalWarehouseId: line.internalWarehouseId,
          internalWarehouseName: line.internalWarehouseName,
        ),
        notice: null,
      ),
    );
  }

  /// Маркируемый товар взят не марками (штрихкодом или из списка) - подсказка (CZ-06).
  void markRequired() =>
      emit(state.copyWith(notice: const MoveNotice.scanMark()));

  /// Отсканированы марки ЧЗ (CZ-06): марка - одна единица, групповая упаковка - её марки,
  /// лежащие в одном месте. Товар и партия - марки, место [from] - где марки лежат с учётом
  /// сеанса, [cell] - ячейка этого места.
  ///
  /// С пустыми руками или с источником, где марки лежат, - марки берутся в руки товаром без
  /// диалога количества. С марками того же товара, партии, склада и места в руках - добавляются
  /// к ним. Источник в руках другой - «нет в источнике»; в руках другое - «сначала положите».
  void takeMarks({
    required List<String> marks,
    required MoveGood good,
    required String productionDate,
    required MovePlace from,
    required Cell cell,
    String? internalWarehouseId,
    String? internalWarehouseName,
  }) {
    // Марки в ячейке приёмки берутся, только если это россыпь с меткой (ADHOC-55).
    final labelled = !from.isBox && internalWarehouseId != null;
    if (marks.isEmpty || !_cellAllowed(cell, labelledSource: labelled)) return;
    final hold = state.hold;
    switch (hold) {
      case HoldGoods(marks: final held) when held.isEmpty:
        emit(state.copyWith(notice: const MoveNotice.putFirst()));
      case final HoldGoods g:
        if (g.good.id != good.id ||
            g.productionDate != productionDate ||
            g.internalWarehouseId != internalWarehouseId ||
            !g.from.samePlace(from)) {
          emit(state.copyWith(notice: const MoveNotice.markOtherGoods()));
          return;
        }
        final fresh = [
          for (final m in marks)
            if (!g.marks.contains(m)) m,
        ];
        if (fresh.isEmpty) {
          emit(state.copyWith(notice: const MoveNotice.markTaken()));
          return;
        }
        emit(
          state.copyWith(
            hold: g.copyWith(
              marks: [...g.marks, ...fresh],
              qty: g.qty + fresh.length,
            ),
            notice: null,
          ),
        );
      case HoldSource(place: final source) when !source.samePlace(from):
        emit(state.copyWith(notice: const MoveNotice.notInSource()));
      default:
        emit(
          state.copyWith(
            hold: MoveHold.goods(
              good: good,
              productionDate: productionDate,
              qty: marks.length.toDouble(),
              from: from,
              internalWarehouseId: internalWarehouseId,
              internalWarehouseName: internalWarehouseName,
              marks: marks,
            ),
            warehouseId: state.warehouseId ?? cell.warehouseId,
            notice: null,
          ),
        );
    }
  }

  /// Положить взятый товар в [to]. Тот же товар той же партии тем же путём - одна строка
  /// с суммой.
  void _put(MovePlace to, Cell cell) {
    final g = state.hold;
    if (g is! HoldGoods) return;
    if (g.from.samePlace(to)) {
      emit(state.copyWith(notice: const MoveNotice.samePlace()));
      return;
    }
    // Короб принадлежит складу целиком: брак кладётся только в короб брака (P6-07-2).
    if (to.isBox && to.internalWarehouseId != g.internalWarehouseId) {
      emit(state.copyWith(notice: const MoveNotice.warehouseMismatch()));
      return;
    }
    final lines = List<MoveLine>.from(state.lines);
    final same = lines.indexWhere(
      (l) =>
          !l.isWholeBox &&
          l.good?.id == g.good.id &&
          l.productionDate == g.productionDate &&
          l.internalWarehouseId == g.internalWarehouseId &&
          l.from.samePlace(g.from) &&
          l.to.samePlace(to),
    );
    if (same >= 0) {
      lines[same] = lines[same].copyWith(
        qty: (lines[same].qty ?? 0) + g.qty,
        marks: [...lines[same].marks, ...g.marks],
      );
    } else {
      lines.add(
        MoveLine(
          good: g.good,
          productionDate: g.productionDate,
          qty: g.qty,
          from: g.from,
          to: to,
          internalWarehouseId: g.internalWarehouseId,
          internalWarehouseName: g.internalWarehouseName,
          marks: g.marks,
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

  /// Ярлык короба, которого нет: на сервере - недействителен; без связи и в снимке - не
  /// проверить.
  void boxNotFound({required bool offline}) => emit(
    state.copyWith(
      notice: offline
          ? const MoveNotice.boxUnknownOffline()
          : const MoveNotice.labelInvalid(),
    ),
  );

  /// Положить обратно - передумал.
  void dropHold() => emit(state.copyWith(hold: null, notice: null));

  /// Убрать строку сеанса - перемещено не туда.
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
    final (:operationId, :result) = await _repo.submit(
      payload(state),
      session: session(state),
    );
    final s = state.copyWith(busy: false);
    emit(
      result.fold(
        (f) => f is RejectedFailure
            ? s.copyWith(
                outcome: MoveOutcome.rejected,
                rejectReason: f.reason,
                rejectedOperationId: operationId,
              )
            : s.copyWith(outcome: MoveOutcome.queued),
        (_) => s.copyWith(outcome: MoveOutcome.posted),
      ),
    );
  }

  /// «Исправить» с экрана отказа: сеанс снова черновик с причиной отказа (ADHOC-41, долг 26).
  ///
  /// Черновик к этому моменту стёрт итогом, поэтому занятым он не бывает; сеанс открывается
  /// заново тем же путём, что после перезапуска, - из черновика.
  Future<void> fixRejected() async {
    final id = state.rejectedOperationId;
    if (id == null) return;
    await _writes; // стирание черновика итогом должно лечь раньше нового черновика
    if (await _repo.reopenRejected(id) != ReopenOutcome.reopened) return;
    emit(const MovementState());
    await init();
  }

  /// Тело операции `movement_submit` - формат эталонов `testdata/movement_submit.json` и
  /// `movement_submit_cz.json` (марки ЧЗ строки, CZ-06).
  ///
  /// У короба ячейку не шлём: сервер берёт её из места короба. Дата партии - в транспортном
  /// виде DD-MM-YYYY. Склад товара шлём только у россыпи не «Основного» склада (P6-07-2): из
  /// короба склад - склад короба, а «Основной» сервер подставляет сам.
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
                if (!l.from.isBox && l.internalWarehouseId != null)
                  'internal_warehouse_id': l.internalWarehouseId,
                if (l.to.isBox)
                  'to_load_unit_id': l.to.loadUnitId
                else
                  'to_cell_id': l.to.cellId,
                if (l.marks.isNotEmpty) 'marks': l.marks,
              },
    ],
  };
}
