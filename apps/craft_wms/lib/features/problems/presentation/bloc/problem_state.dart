import 'package:freezed_annotation/freezed_annotation.dart';

import '../../../../core/problems/problem_reasons.dart';
import '../../../contents/domain/contents_entities.dart';
import '../../../stock/domain/catalog_models.dart';
import '../../domain/problem_photos.dart';

part 'problem_state.freezed.dart';

/// Где ищем помеченное: отсканированный короб или ячейка с её коробами и россыпью.
@freezed
sealed class ProblemSource with _$ProblemSource {
  const factory ProblemSource.box({
    required LoadUnitView box,
    required Cell cell,
  }) = SourceBox;

  const factory ProblemSource.cell({
    required Cell cell,
    required CellView view,
  }) = SourceCell;
}

/// Что помечаем: короб целиком ЛИБО товар партии с количеством - из короба или из россыпи.
@freezed
sealed class ProblemSubject with _$ProblemSubject {
  const factory ProblemSubject.wholeBox({
    required LoadUnitView box,
    required Cell cell,
  }) = SubjectBox;

  /// Товар; [box] - из этого короба (вынимается в россыпь склада назначения), `null` - из
  /// россыпи ячейки. [marks] - КИ марок ЧЗ помеченных единиц (CZ-06): маркируемый товар
  /// помечают марками, количество - их число.
  const factory ProblemSubject.goods({
    required ContentLine line,
    required double qty,
    required Cell cell,
    LoadUnitView? box,
    @Default(<String>[]) List<String> marks,
  }) = SubjectGoods;

  const ProblemSubject._();

  /// Склад помечаемого сейчас (`null` - «Основной»): назначение должно отличаться.
  String? get fromWarehouseId => switch (this) {
    SubjectBox(:final box) => box.internalWarehouseId,
    SubjectGoods(:final line) => line.internalWarehouseId,
  };

  Cell get place => switch (this) {
    SubjectBox(:final cell) => cell,
    SubjectGoods(:final cell) => cell,
  };
}

/// Итог фиксации.
enum ProblemOutcome {
  /// Сервер провёл.
  posted,

  /// Связи нет: проблема в очереди и уйдёт сама.
  queued,

  /// Сервер отказал по существу; проблема ждёт разбора на экране несинхронизированного.
  rejected,
}

/// Подсказка по результату скана - показывается один раз.
@freezed
sealed class ProblemNotice with _$ProblemNotice {
  /// Ячейка приёмки: её содержимое разносит задание на размещение.
  const factory ProblemNotice.receivingCell() = ProblemNoticeReceivingCell;

  /// Короб пуст или не размещён - помечать нечего.
  const factory ProblemNotice.boxEmpty() = ProblemNoticeBoxEmpty;

  /// Ячейка пуста - ни коробов, ни россыпи.
  const factory ProblemNotice.cellEmpty() = ProblemNoticeCellEmpty;

  /// Ярлык недействителен: такого короба нет на сервере.
  const factory ProblemNotice.labelInvalid() = ProblemNoticeLabelInvalid;

  /// Короба нет в снимке терминала, а связи нет.
  const factory ProblemNotice.boxUnknownOffline() =
      ProblemNoticeBoxUnknownOffline;

  /// Эта марка уже в проблеме (CZ-06).
  const factory ProblemNotice.markTaken() = ProblemNoticeMarkTaken;

  /// Марка другого товара, партии или места, чем уже отмеченные (CZ-06).
  const factory ProblemNotice.markOtherGoods() = ProblemNoticeMarkOtherGoods;
}

/// Состояние экрана «Проблемы склада» (P6-07-2): одна проблема - одна операция.
///
/// Скан короба или ячейки → короб целиком или товар с количеством → склад → причина →
/// комментарий → «Зафиксировать».
@freezed
abstract class ProblemState with _$ProblemState {
  const factory ProblemState({
    /// Идентификатор проблемы - выдаёт терминал: фиксация идёт и без связи.
    String? problemId,
    ProblemSource? source,
    ProblemSubject? subject,
    String? toWarehouseId,
    ProblemReason? reason,
    @Default('') String comment,
    @Default('') String mark,
    @Default(false) bool busy,
    ProblemOutcome? outcome,
    String? rejectReason,
    ProblemNotice? notice,

    /// Снимки к проблеме (ADHOC-45), до [kProblemPhotoMax]; уходят своей очередью вслед за ней.
    @Default(<ProblemPhotoShot>[]) List<ProblemPhotoShot> photos,
  }) = _ProblemState;

  const ProblemState._();

  /// Можно фиксировать: выбрано что, куда и почему; у причины с обязательным комментарием
  /// (ADHOC-55) он есть.
  bool get canSubmit =>
      subject != null &&
      toWarehouseId != null &&
      reason != null &&
      (!reason!.commentRequired || comment.trim().isNotEmpty) &&
      !busy &&
      outcome == null;
}
