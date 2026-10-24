import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:injectable/injectable.dart';

import '../../../../core/error/failure.dart';
import '../../../../core/load_unit/load_unit_id_generator.dart';
import '../../../../core/warehouse/internal_warehouses.dart';
import '../../../contents/domain/contents_entities.dart';
import '../../../stock/data/catalog_models.dart';
import '../../domain/problem_models.dart';
import '../../domain/problem_photos.dart';
import '../../domain/problem_repository.dart';
import 'problem_state.dart';

/// Cubit «Проблем склада» на ТСД (P6-07-2): одна проблема — одна операция `problem_submit`.
///
/// Решения о потоке — здесь, без сети и базы: экран находит короб и ячейку и передаёт
/// найденное. Правила те же, что у сервера: ячейка приёмки не годится (её разносит задание на
/// размещение); часть короба вынимается в россыпь склада назначения той же ячейки; склад
/// назначения — не тот, где товар уже лежит.
@injectable
class ProblemCubit extends Cubit<ProblemState> {
  ProblemCubit(this._repo, this._ids, this._photos, this._camera)
    : super(const ProblemState());

  final ProblemRepository _repo;
  final LoadUnitIdGenerator _ids;
  final ProblemPhotoRepository _photos;
  final PhotoCamera _camera;

  /// Склады, которыми можно пометить, — для выбора на экране.
  List<InternalWarehouse> warehouses = const [];

  /// Начать: новый идентификатор проблемы и склады для выбора.
  Future<void> init() async {
    warehouses = await _repo.markWarehouses();
    if (isClosed) return;
    emit(ProblemState(problemId: _ids.newId()));
  }

  //* --- что помечаем --- *//

  /// Отсканирован короб. [cell] — где он лежит; `null` — не размещён.
  void onBox(LoadUnitView box, Cell? cell) {
    if (cell == null || !box.live) {
      emit(state.copyWith(notice: const ProblemNotice.boxEmpty()));
      return;
    }
    if (!_cellAllowed(cell)) return;
    emit(
      state.copyWith(
        source: ProblemSource.box(box: box, cell: cell),
        subject: null,
        toWarehouseId: null,
        notice: null,
      ),
    );
  }

  /// Отсканирована или выбрана ячейка: её короба и россыпь — на выбор.
  void onCell(Cell cell, CellView view) {
    if (!_cellAllowed(cell)) return;
    if (view.isEmpty) {
      emit(state.copyWith(notice: const ProblemNotice.cellEmpty()));
      return;
    }
    emit(
      state.copyWith(
        source: ProblemSource.cell(cell: cell, view: view),
        subject: null,
        toWarehouseId: null,
        notice: null,
      ),
    );
  }

  bool _cellAllowed(Cell cell) {
    if (!cell.isDefault) return true;
    emit(state.copyWith(notice: const ProblemNotice.receivingCell()));
    return false;
  }

  /// Пометить короб из источника целиком.
  void chooseWholeBox() {
    final s = state.source;
    if (s is! SourceBox) return;
    _choose(ProblemSubject.wholeBox(box: s.box, cell: s.cell));
  }

  /// Пометить товар партии [line] количеством [qty] — из короба источника или из россыпи
  /// ячейки. Больше, чем лежит, не берётся.
  void chooseGoods(ContentLine line, double qty) {
    if (qty <= 0 || qty > line.qty) return;
    switch (state.source) {
      case SourceBox(:final box, :final cell):
        _choose(
          ProblemSubject.goods(line: line, qty: qty, cell: cell, box: box),
        );
      case SourceCell(:final cell):
        _choose(ProblemSubject.goods(line: line, qty: qty, cell: cell));
      case null:
        return;
    }
  }

  /// Выбрать помечаемое; склад назначения подставляется, если выбирать не из чего.
  void _choose(ProblemSubject subject) {
    final targets = targetsFor(subject);
    emit(
      state.copyWith(
        subject: subject,
        toWarehouseId: targets.length == 1 ? targets.single.id : null,
        notice: null,
      ),
    );
  }

  /// Куда можно пометить: склады, кроме того, где товар уже лежит.
  List<InternalWarehouse> targetsFor(ProblemSubject subject) => [
    for (final w in warehouses)
      if (w.id != subject.fromWarehouseId) w,
  ];

  //* --- куда и почему --- *//

  void setWarehouse(String id) =>
      emit(state.copyWith(toWarehouseId: id, notice: null));

  void setReason(ProblemReason reason) =>
      emit(state.copyWith(reason: reason, notice: null));

  void setComment(String text) => emit(state.copyWith(comment: text));

  void setMark(String text) => emit(state.copyWith(mark: text));

  /// Шаг назад: от формы — к выбору в источнике, от выбора — к скану.
  void back() => emit(
    state.subject != null
        ? state.copyWith(subject: null, toWarehouseId: null, notice: null)
        : state.copyWith(source: null, notice: null),
  );

  /// Подсказка показана.
  void clearNotice() => emit(state.copyWith(notice: null));

  /// Ярлык короба, которого нет: на сервере — недействителен; без связи — не проверить.
  void boxNotFound({required bool offline}) => emit(
    state.copyWith(
      notice: offline
          ? const ProblemNotice.boxUnknownOffline()
          : const ProblemNotice.labelInvalid(),
    ),
  );

  /// Следующая проблема — с чистого листа (причина остаётся: брак идёт пачками).
  void next() =>
      emit(ProblemState(problemId: _ids.newId(), reason: state.reason));

  //* --- фото (ADHOC-45) --- *//

  /// Снять фото камерой терминала. Больше [kProblemPhotoMax] не берём; отмену съёмки — молча.
  Future<void> takePhoto() async {
    if (state.photos.length >= kProblemPhotoMax || state.outcome != null) {
      return;
    }
    final content = await _camera.take();
    if (content == null || isClosed) return;
    emit(
      state.copyWith(
        photos: [
          ...state.photos,
          ProblemPhotoShot(id: _ids.newId(), content: content),
        ],
      ),
    );
  }

  /// Убрать снимок до фиксации.
  void removePhoto(String id) =>
      emit(state.copyWith(photos: [...state.photos.where((p) => p.id != id)]));

  //* --- фиксация --- *//

  /// Зафиксировать: поставить в очередь и попробовать отправить.
  Future<void> submit() async {
    if (!state.canSubmit) return;
    emit(state.copyWith(busy: true, notice: null));
    final res = await _repo.submit(payload(state));
    // Снимки — вслед за проблемой, своей очередью: и проведённой, и ждущей связи. Отклонённой
    // проблемы на сервере не будет — её снимкам некуда лечь.
    if (!(res.isLeft && res.left is RejectedFailure) &&
        state.photos.isNotEmpty) {
      await _photos.enqueue(state.problemId!, state.photos);
    }
    final s = state.copyWith(busy: false);
    emit(
      res.fold(
        (f) => f is RejectedFailure
            ? s.copyWith(
                outcome: ProblemOutcome.rejected,
                rejectReason: f.reason,
              )
            : s.copyWith(outcome: ProblemOutcome.queued),
        (_) => s.copyWith(outcome: ProblemOutcome.posted),
      ),
    );
  }

  /// Тело операции `problem_submit` — формат эталона `testdata/problem_submit.json`.
  ///
  /// Короб целиком — только его id: склад и ячейку сервер знает сам. Товар из короба —
  /// короб-источник; из россыпи — ячейка и склад россыпи, если он не «Основной». Дата партии —
  /// DD-MM-YYYY. Марка — только если отсканирована.
  @visibleForTesting
  static Map<String, dynamic> payload(ProblemState s) {
    final subject = s.subject!;
    final mark = s.mark.trim();
    return {
      'problem_id': s.problemId,
      'warehouse_id': subject.place.warehouseId,
      ...switch (subject) {
        SubjectBox(:final box) => {'load_unit_id': box.id},
        SubjectGoods(:final line, :final qty, :final cell, :final box) => {
          'good_id': line.goodId,
          'production_date': line.productionDate,
          'qty': qty,
          if (box != null)
            'from_load_unit_id': box.id
          else ...{
            'cell_id': cell.id,
            if (line.internalWarehouseId != null)
              'internal_warehouse_id': line.internalWarehouseId,
          },
        },
      },
      'to_internal_warehouse_id': s.toWarehouseId,
      'reason': s.reason!.wire,
      if (s.comment.trim().isNotEmpty) 'comment': s.comment.trim(),
      if (mark.isNotEmpty) 'mark': mark,
    };
  }
}
