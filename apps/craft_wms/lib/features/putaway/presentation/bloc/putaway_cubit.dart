import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:injectable/injectable.dart';

import '../../../../core/error/failure.dart';
import '../../../../core/load_unit/load_unit_id_generator.dart';
import '../../../../core/outbox/sent_sessions.dart';
import '../../../stock/domain/catalog_models.dart';
import '../../../tasks/domain/tasks_models.dart';
import '../../domain/putaway_drafts.dart';
import '../../domain/putaway_repository.dart';
import 'putaway_models.dart';

part 'putaway_cubit.freezed.dart';

/// Состояние экрана размещения (P5-03).
///
/// Поток по заданию: скан короба или товара (россыпь - партия и количество из задания) →
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

    /// Операция отклонённого сеанса - по ней «Исправить» вернёт сеанс в черновик (ADHOC-41).
    String? rejectedOperationId,

    /// Сеанс вернулся из отказа: причина отказа сервера видна, пока сеанс не завершён снова.
    String? fixReason,
    PutawayNotice? notice,

    /// На терминале лежит незавершённый сеанс ДРУГОГО задания - его номер. Пока он не решён,
    /// начинать новый нельзя: черновик один, и новый затёр бы чужую работу.
    int? foreignDraftNumber,

    /// Идентификатор задания того сеанса - чтобы при отбрасывании вернуть его в пул.
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

/// Cubit размещения на ТСД (P5-03). Фабрика - свой на экран и задание.
@injectable
class PutawayCubit extends Cubit<PutawayState> {
  PutawayCubit(
    this._repo,
    this._drafts,
    this._ids,
    @factoryParam WarehouseTask task,
  ) : super(PutawayState(task: task));

  final PutawayRepository _repo;
  final PutawayDrafts _drafts;
  final LoadUnitIdGenerator _ids;

  /// Очередь записей черновика - тот же приём, что у приёмки: два быстрых изменения подряд
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
          fixReason: draft['fix_reason'] as String?,
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

  /// Отбросить чужой незавершённый сеанс и начать этот - по явному решению кладовщика.
  ///
  /// Задание того сеанса возвращается в пул: работа по нему брошена, и держать его взятым
  /// значило бы спрятать от остальных до авто-возврата через 8 часов. Без связи отдать его
  /// нельзя - кладовщик узнаёт, что оно вернётся само.
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
    // Пока не решён чужой черновик, свой не пишем - иначе затрём чужую работу.
    if (state.foreignDraftNumber != null || state.putawayId == null) return;
    final done = state.outcome != null;
    final snapshot = done ? null : session(state);
    _writes = _writes
        .then(
          (_) => snapshot == null ? _drafts.clear() : _drafts.save(snapshot),
        )
        .catchError((_) {});
  }

  /// Слепок сеанса - черновик и копия отправленного документа (ADHOC-41) в одном виде.
  @visibleForTesting
  static Map<String, dynamic> session(PutawayState s) => {
    'task_id': s.task.id,
    'task_number': s.task.number,
    'putaway_id': s.putawayId,
    'lines': s.lines.map((l) => l.toJson()).toList(),
    'pick': s.pick?.toJson(),
    if (s.fixReason != null) 'fix_reason': s.fixReason,
  };

  /// Дождаться записи черновика - нужно только тестам.
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
    emit(
      state.copyWith(
        pick: PutawayPick(loadUnitId: id, czCode: item.czCode),
        notice: null,
      ),
    );
  }

  /// Взять короб ЧЗ по коду `00`+SSCC с его этикетки (CZ-06): ярлыка WMS у короба ЧЗ нет,
  /// задание знает его код - короб находится и без связи.
  void pickCzBox(String czCode) {
    final item = state.task.items
        .where((i) => i.isBox && i.czCode == czCode)
        .firstOrNull;
    if (item == null) {
      emit(state.copyWith(notice: const PutawayNotice.notInTask()));
      return;
    }
    pickBox(item.loadUnitId!);
  }

  /// Россыпь задания по товару: позиции с остатком - экран выбирает партию и количество.
  /// Пусто - товара в задании нет или он уже весь положен.
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

  /// Взять в руки россыпь: партия из задания, количество - не больше остатка.
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

  /// Взять россыпь марками ЧЗ (CZ-06): марки товара [goodId] партии [productionDate],
  /// лежащие россыпью в ячейке приёмки. Партия - позиция задания; к взятым марками того же
  /// товара и партии марки добавляются, не больше остатка позиции.
  void pickMarks(List<String> marks, String goodId, String productionDate) {
    final used = {
      for (final l in state.lines) ...l.pick.marks,
      ...?state.pick?.marks,
    };
    final fresh = [
      for (final m in marks)
        if (!used.contains(m)) m,
    ];
    if (fresh.isEmpty) {
      emit(state.copyWith(notice: const PutawayNotice.markTaken()));
      return;
    }
    final item = state.task.items
        .where(
          (i) =>
              !i.isBox &&
              i.good?.id == goodId &&
              i.productionDate == productionDate,
        )
        .firstOrNull;
    if (item == null) {
      emit(state.copyWith(notice: const PutawayNotice.notInTask()));
      return;
    }
    final pick = state.pick;
    final held =
        pick != null &&
            pick.marks.isNotEmpty &&
            pick.good?.id == goodId &&
            pick.productionDate == productionDate
        ? pick.marks
        : const <String>[];
    final all = [...held, ...fresh];
    if (all.length > state.looseLeft(item)) {
      emit(state.copyWith(notice: const PutawayNotice.alreadyPlaced()));
      return;
    }
    emit(
      state.copyWith(
        pick: PutawayPick(
          good: item.good,
          productionDate: item.productionDate,
          qty: all.length.toDouble(),
          marks: all,
        ),
        notice: null,
      ),
    );
  }

  /// Положить обратно - передумал.
  void dropPick() => emit(state.copyWith(pick: null, notice: null));

  //* --- ячейка --- *//

  /// Скан ячейки: взятое ложится в неё строкой сеанса.
  ///
  /// Ячейка приёмки не годится - из неё размещают; ячейка другого склада - тоже: сервер
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
    // Та же россыпь той же партии в ту же ячейку - одна строка с суммой.
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
        pick: prev.copyWith(
          qty: (prev.qty ?? 0) + (pick.qty ?? 0),
          marks: [...prev.marks, ...pick.marks],
        ),
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

  /// Убрать строку сеанса - положено не туда.
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
    final (:operationId, :result) = await _repo.submit(
      payload: payload(state),
      session: session(state),
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
      result.fold(
        (f) => f is RejectedFailure
            ? s.copyWith(
                outcome: PutawayOutcome.rejected,
                rejectReason: f.reason,
                rejectedOperationId: operationId,
              )
            : s.copyWith(outcome: PutawayOutcome.queued),
        (_) => s.copyWith(outcome: PutawayOutcome.posted),
      ),
    );
  }

  /// «Исправить» с экрана отказа: сеанс снова черновик с причиной отказа (ADHOC-41, долг 26).
  ///
  /// Черновик к этому моменту стёрт итогом, поэтому занятым он не бывает; сеанс открывается
  /// заново тем же путём, что после перезапуска, - из черновика этого задания.
  Future<void> fixRejected() async {
    final id = state.rejectedOperationId;
    if (id == null) return;
    await _writes; // стирание черновика итогом должно лечь раньше нового черновика
    final (outcome, _) = await _repo.reopenRejected(id);
    if (outcome != ReopenOutcome.reopened) return;
    emit(PutawayState(task: state.task));
    await init();
  }

  /// Тело операции `putaway_submit` - формат эталона `testdata/putaway_submit.json`.
  ///
  /// Ячейку-источник не шлём: короб сервер берёт оттуда, где он числится, россыпь - из ячейки
  /// приёмки. Дата партии - в транспортном виде DD-MM-YYYY, как пришла в задании.
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
                if (l.pick.marks.isNotEmpty) 'marks': l.pick.marks,
              },
    ],
  };
}
