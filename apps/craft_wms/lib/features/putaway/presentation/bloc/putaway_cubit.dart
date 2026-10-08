import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:injectable/injectable.dart';

import '../../../../core/error/failure.dart';
import '../../../../core/load_unit/load_unit_id_generator.dart';
import '../../../stock/data/catalog_models.dart';
import '../../../tasks/data/tasks_models.dart';
import '../../data/putaway_draft_store.dart';
import '../../data/putaway_repository.dart';
import 'putaway_models.dart';

part 'putaway_cubit.freezed.dart';

/// Состояние экрана размещения (P5-03).
///
/// Поток по заданию: скан короба или товара (россыпь — партия и количество из задания) →
/// скан ячейки → строка ложится в сеанс → … → «Завершить». Всё копится на терминале и уходит
/// на сервер одной операцией очереди `putaway_submit`.
@freezed
abstract class PutawayState with _$PutawayState {
  const factory PutawayState({
    required WarehouseTask task,

    /// Идентификатор документа размещения. Выдаёт терминал: сеанс идёт и без связи.
    String? putawayId,
    @Default(<PutawayLine>[]) List<PutawayLine> lines,

    /// Взято в руки и ждёт ячейки.
    PutawayPick? pick,
    @Default(false) bool busy,
    PutawayOutcome? outcome,
    String? rejectReason,
    PutawayNotice? notice,

    /// На терминале лежит незавершённый сеанс ДРУГОГО задания — его номер. Пока он не решён,
    /// начинать новый нельзя: черновик один, и новый затёр бы чужую работу.
    int? foreignDraftNumber,

    /// Идентификатор задания того сеанса — чтобы при отбрасывании вернуть его в пул.
    String? foreignDraftTaskId,
  }) = _PutawayState;

  const PutawayState._();

  /// Короба задания, которые ещё предстоит разместить в этом заходе.
  List<TaskItem> get openBoxes => [
    for (final it in task.items)
      if (it.isBox && !it.placed && !_boxInLines(it.loadUnitId!)) it,
  ];

  /// Россыпь задания с остатком с учётом уже положенного в этом заходе.
  List<(TaskItem, double)> get openLoose => [
    for (final it in task.items)
      if (!it.isBox)
        if (looseLeft(it) case final left when left > 0) (it, left),
  ];

  /// Сколько россыпи позиции ещё не положено: остаток задания минус строки сеанса.
  double looseLeft(TaskItem item) {
    final remaining = double.tryParse(item.remaining ?? '') ?? 0;
    final taken = lines
        .where(
          (l) =>
              !l.pick.isBox &&
              l.pick.good?.id == item.good?.id &&
              l.pick.productionDate == item.productionDate,
        )
        .fold<double>(0, (sum, l) => sum + (l.pick.qty ?? 0));
    return remaining - taken;
  }

  bool _boxInLines(String id) => lines.any((l) => l.pick.loadUnitId == id);

  /// Можно завершать: что-то положено, отправка не идёт, сеанс не завершён.
  bool get canSubmit => lines.isNotEmpty && !busy && outcome == null;
}

/// Cubit размещения на ТСД (P5-03). Фабрика — свой на экран и задание.
@injectable
class PutawayCubit extends Cubit<PutawayState> {
  PutawayCubit(
    this._repo,
    this._drafts,
    this._ids,
    @factoryParam WarehouseTask task,
  ) : super(PutawayState(task: task));

  final PutawayRepository _repo;
  final PutawayDraftStore _drafts;
  final LoadUnitIdGenerator _ids;

  /// Очередь записей черновика — тот же приём, что у приёмки: два быстрых изменения подряд
  /// иначе легли бы в базу в обратном порядке.
  Future<void> _writes = Future<void>.value();

  //* --- черновик --- *//

  /// Открыть сеанс: восстановить незавершённый по этому заданию или начать новый.
  Future<void> init() async {
    final draft = await _drafts.load();
    if (draft != null && draft['task_id'] != state.task.id) {
      emit(
        state.copyWith(
          foreignDraftNumber: draft['task_number'] as int? ?? 0,
          foreignDraftTaskId: draft['task_id'] as String?,
        ),
      );
      return;
    }
    if (draft != null) {
      emit(
        state.copyWith(
          putawayId: draft['putaway_id'] as String?,
          lines: [
            for (final e in draft['lines'] as List<dynamic>? ?? const [])
              PutawayLine.fromJson(e as Map<String, dynamic>),
          ],
          pick: switch (draft['pick']) {
            final Map<String, dynamic> p => PutawayPick.fromJson(p),
            _ => null,
          },
        ),
      );
      return;
    }
    emit(state.copyWith(putawayId: _ids.newId()));
  }

  /// Отбросить чужой незавершённый сеанс и начать этот — по явному решению кладовщика.
  ///
  /// Задание того сеанса возвращается в пул: работа по нему брошена, и держать его взятым
  /// значило бы спрятать от остальных до авто-возврата через 8 часов. Без связи отдать его
  /// нельзя — кладовщик узнаёт, что оно вернётся само.
  Future<void> discardForeignDraft() async {
    final number = state.foreignDraftNumber ?? 0;
    final taskId = state.foreignDraftTaskId;
    await _drafts.clear();
    final released =
        taskId == null || (await _repo.releaseTask(taskId)).isRight;
    emit(
      state.copyWith(
        foreignDraftNumber: null,
        foreignDraftTaskId: null,
        putawayId: _ids.newId(),
        notice: released ? null : PutawayNotice.releaseOffline(number),
      ),
    );
  }

  /// Сохранение черновика повешено на [emit]: метод, добавленный позже, про сохранение забыл
  /// бы, а один перехват на все изменения забыть невозможно (приём приёмки).
  @override
  void emit(PutawayState state) {
    super.emit(state);
    // Пока не решён чужой черновик, свой не пишем — иначе затрём чужую работу.
    if (state.foreignDraftNumber != null || state.putawayId == null) return;
    final done = state.outcome != null;
    final snapshot = done
        ? null
        : {
            'task_id': state.task.id,
            'task_number': state.task.number,
            'putaway_id': state.putawayId,
            'lines': state.lines.map((l) => l.toJson()).toList(),
            'pick': state.pick?.toJson(),
          };
    _writes = _writes
        .then(
          (_) => snapshot == null ? _drafts.clear() : _drafts.save(snapshot),
        )
        .catchError((_) {});
  }

  /// Дождаться записи черновика — нужно только тестам.
  @visibleForTesting
  Future<void> get draftWrites => _writes;

  //* --- что взято --- *//

  /// Скан ярлыка короба: короб задания, ещё не размещённый, берётся в руки.
  void pickBox(String loadUnitId) {
    final id = loadUnitId.toLowerCase();
    final item = state.task.items
        .where((i) => i.isBox && i.loadUnitId == id)
        .firstOrNull;
    if (item == null) {
      emit(state.copyWith(notice: const PutawayNotice.notInTask()));
      return;
    }
    if (item.placed || state.lines.any((l) => l.pick.loadUnitId == id)) {
      emit(state.copyWith(notice: const PutawayNotice.alreadyPlaced()));
      return;
    }
    emit(state.copyWith(pick: PutawayPick(loadUnitId: id), notice: null));
  }

  /// Россыпь задания по товару: позиции с остатком — экран выбирает партию и количество.
  /// Пусто — товара в задании нет или он уже весь положен.
  List<(TaskItem, double)> looseOf(String goodId) =>
      state.openLoose.where((e) => e.$1.good?.id == goodId).toList();

  /// Товар, которого в задании нет или который уже положен целиком.
  void looseUnavailable({required bool inTask}) => emit(
    state.copyWith(
      notice: inTask
          ? const PutawayNotice.alreadyPlaced()
          : const PutawayNotice.notInTask(),
    ),
  );

  /// Взять в руки россыпь: партия из задания, количество — не больше остатка.
  void pickLoose(TaskItem item, double qty) {
    final left = state.looseLeft(item);
    if (qty <= 0 || qty > left) return;
    emit(
      state.copyWith(
        pick: PutawayPick(
          good: item.good,
          productionDate: item.productionDate,
          qty: qty,
        ),
        notice: null,
      ),
    );
  }

  /// Положить обратно — передумал.
  void dropPick() => emit(state.copyWith(pick: null, notice: null));

  //* --- ячейка --- *//

  /// Скан ячейки: взятое ложится в неё строкой сеанса.
  ///
  /// Ячейка приёмки не годится — из неё размещают; ячейка другого склада — тоже: сервер
  /// отклонил бы из-за неё весь сеанс, а здесь это видно сразу.
  void placeIn(Cell cell) {
    final pick = state.pick;
    if (pick == null) {
      emit(state.copyWith(notice: const PutawayNotice.pickFirst()));
      return;
    }
    if (cell.isDefault) {
      emit(state.copyWith(notice: const PutawayNotice.receivingCell()));
      return;
    }
    if (cell.warehouseId != state.task.warehouseId) {
      emit(state.copyWith(notice: const PutawayNotice.foreignCell()));
      return;
    }
    final lines = List<PutawayLine>.from(state.lines);
    // Та же россыпь той же партии в ту же ячейку — одна строка с суммой.
    final same = pick.isBox
        ? -1
        : lines.indexWhere(
            (l) =>
                !l.pick.isBox &&
                l.cell.id == cell.id &&
                l.pick.good?.id == pick.good?.id &&
                l.pick.productionDate == pick.productionDate,
          );
    if (same >= 0) {
      final prev = lines[same].pick;
      lines[same] = lines[same].copyWith(
        pick: prev.copyWith(qty: (prev.qty ?? 0) + (pick.qty ?? 0)),
      );
    } else {
      lines.add(PutawayLine(pick: pick, cell: cell));
    }
    emit(
      state.copyWith(
        lines: lines,
        pick: null,
        notice: PutawayNotice.placed(cell.address),
      ),
    );
  }

  /// Убрать строку сеанса — положено не туда.
  void removeLine(PutawayLine line) {
    final lines = List<PutawayLine>.from(state.lines);
    if (!lines.remove(line)) return;
    emit(state.copyWith(lines: lines, notice: null));
  }

  /// Подсказка показана.
  void clearNotice() => emit(state.copyWith(notice: null));

  //* --- завершение --- *//

  /// Завершить сеанс: поставить в очередь одной операцией и попробовать отправить.
  ///
  /// Неразмещённое остаётся в задании, и задание возвращается в общий пул (решение
  /// 2026-10-07): «Завершить» доступно и при частичном размещении.
  Future<void> submit() async {
    if (!state.canSubmit) return;
    emit(state.copyWith(busy: true, notice: null));
    final res = await _repo.submit(
      payload: payload(state),
      taskId: state.task.id,
      boxes: {
        for (final l in state.lines)
          if (l.pick.isBox) l.pick.loadUnitId!,
      },
      loose: {
        for (final l in state.lines)
          if (!l.pick.isBox)
            (l.pick.good!.id, l.pick.productionDate!): state.lines
                .where(
                  (x) =>
                      !x.pick.isBox &&
                      x.pick.good?.id == l.pick.good?.id &&
                      x.pick.productionDate == l.pick.productionDate,
                )
                .fold<double>(0, (s, x) => s + (x.pick.qty ?? 0)),
      },
    );
    final s = state.copyWith(busy: false);
    emit(
      res.fold(
        (f) => f is RejectedFailure
            ? s.copyWith(
                outcome: PutawayOutcome.rejected,
                rejectReason: f.reason,
              )
            : s.copyWith(outcome: PutawayOutcome.queued),
        (_) => s.copyWith(outcome: PutawayOutcome.posted),
      ),
    );
  }

  /// Тело операции `putaway_submit` — формат эталона `testdata/putaway_submit.json`.
  ///
  /// Ячейку-источник не шлём: короб сервер берёт оттуда, где он числится, россыпь — из ячейки
  /// приёмки. Дата партии — в транспортном виде DD-MM-YYYY, как пришла в задании.
  @visibleForTesting
  static Map<String, dynamic> payload(PutawayState s) => {
    'putaway_id': s.putawayId,
    'task_id': s.task.id,
    'warehouse_id': s.task.warehouseId,
    'lines': [
      for (final l in s.lines)
        l.pick.isBox
            ? {'load_unit_id': l.pick.loadUnitId, 'to_cell_id': l.cell.id}
            : {
                'good_id': l.pick.good!.id,
                'production_date': l.pick.productionDate,
                'qty': l.pick.qty,
                'to_cell_id': l.cell.id,
              },
    ],
  };
}
