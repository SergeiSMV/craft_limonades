import 'package:freezed_annotation/freezed_annotation.dart';

import '../../../stock/domain/catalog_models.dart';
import '../../../tasks/data/tasks_models.dart';

part 'putaway_models.freezed.dart';
part 'putaway_models.g.dart';

/// Модели сеанса размещения на ТСД (P5-03).

/// Что взято в руки и ждёт ячейки: короб целиком ЛИБО россыпь (товар, партия, количество).
///
/// Порядок «товар → ячейка» (решение 2026-10-07): каждый перенос заканчивается сканом ячейки,
/// поэтому положить в «прошлую» ячейку по забывчивости нельзя.
@freezed
abstract class PutawayPick with _$PutawayPick {
  const factory PutawayPick({
    @JsonKey(name: 'load_unit_id') String? loadUnitId,
    TaskGood? good,
    @JsonKey(name: 'production_date') String? productionDate,
    double? qty,

    /// Код короба ЧЗ взятого короба (CZ-06) - для подписи; `null` - свой короб или россыпь.
    @JsonKey(name: 'cz_code') String? czCode,

    /// КИ марок ЧЗ взятой россыпи (CZ-06): маркируемый товар берут марками, количество -
    /// их число.
    @Default(<String>[]) List<String> marks,
  }) = _PutawayPick;

  const PutawayPick._();

  bool get isBox => loadUnitId != null;

  factory PutawayPick.fromJson(Map<String, dynamic> json) =>
      _$PutawayPickFromJson(json);
}

/// Строка сеанса: что и в какую ячейку положили.
@freezed
abstract class PutawayLine with _$PutawayLine {
  const factory PutawayLine({required PutawayPick pick, required Cell cell}) =
      _PutawayLine;

  factory PutawayLine.fromJson(Map<String, dynamic> json) =>
      _$PutawayLineFromJson(json);
}

/// Итог отправки сеанса.
enum PutawayOutcome {
  /// Сервер провёл сеанс.
  posted,

  /// Связи нет: сеанс в очереди и уйдёт сам. Работа не потеряна.
  queued,

  /// Сервер отказал по существу; сеанс ждёт разбора на экране несинхронизированного.
  rejected,
}

/// Подсказка кладовщику по результату скана - показывается один раз.
@freezed
sealed class PutawayNotice with _$PutawayNotice {
  /// Отсканированного нет в задании.
  const factory PutawayNotice.notInTask() = NoticeNotInTask;

  /// Это уже размещено - этим заданием раньше или в этом заходе.
  const factory PutawayNotice.alreadyPlaced() = NoticeAlreadyPlaced;

  /// Отсканирована ячейка, а в руках ничего: сначала короб или товар.
  const factory PutawayNotice.pickFirst() = NoticePickFirst;

  /// Это ячейка приёмки - размещают из неё, а не в неё.
  const factory PutawayNotice.receivingCell() = NoticeReceivingCell;

  /// Ячейка другого склада.
  const factory PutawayNotice.foreignCell() = NoticeForeignCell;

  /// Положено в ячейку.
  const factory PutawayNotice.placed(String address) = NoticePlaced;

  /// Эта марка уже взята или положена в этом сеансе (CZ-06).
  const factory PutawayNotice.markTaken() = NoticeMarkTaken;

  /// Отброшенное задание вернуть в пул не удалось - нет связи; вернётся само по зависанию.
  const factory PutawayNotice.releaseOffline(int number) = NoticeReleaseOffline;
}
