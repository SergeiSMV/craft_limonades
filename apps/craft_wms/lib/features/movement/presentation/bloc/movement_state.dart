import 'package:freezed_annotation/freezed_annotation.dart';

import '../../../contents/domain/contents_entities.dart';
import '../../domain/movement_models.dart';

part 'movement_state.freezed.dart';

/// Что в руках у кладовщика (P6-04).
@freezed
sealed class MoveHold with _$MoveHold {
  /// Отсканирован источник — короб или россыпь ячейки — и его состав на момент скана.
  ///
  /// Судьбу короба решает следующий скан (решение 2026-10-13): ячейка — короб едет целиком,
  /// товар — берётся из короба. Состав — без строк этого сеанса: их накладывает
  /// [MovementState.available].
  const factory MoveHold.source({
    required MovePlace place,
    required List<ContentLine> contents,

    /// Короб выбран вручную, без скана ярлыка: ярлык, вероятно, испорчен — карточка предлагает
    /// перепечатать его на месте.
    @Default(false) bool manual,
  }) = HoldSource;

  /// Взят товар: партия и количество из источника, ждёт приёмника — ячейки или короба.
  const factory MoveHold.goods({
    required MoveGood good,
    required String productionDate,
    required double qty,
    required MovePlace from,

    /// Склад взятого товара (P6-07-2); `null` — «Основной».
    String? internalWarehouseId,
    String? internalWarehouseName,
  }) = HoldGoods;
}

/// Итог отправки сеанса.
enum MoveOutcome {
  /// Сервер провёл сеанс.
  posted,

  /// Связи нет: сеанс в очереди и уйдёт сам. Работа не потеряна.
  queued,

  /// Сервер отказал по существу; сеанс ждёт разбора на экране несинхронизированного.
  rejected,
}

/// Подсказка кладовщику по результату скана — показывается один раз.
@freezed
sealed class MoveNotice with _$MoveNotice {
  /// Товар отсканирован, а источника нет: сначала ячейка или короб.
  const factory MoveNotice.sourceFirst() = NoticeSourceFirst;

  /// В руках товар — сначала положить его.
  const factory MoveNotice.putFirst() = NoticePutFirst;

  /// Этого товара в источнике нет (или он уже весь взят в этом сеансе).
  const factory MoveNotice.notInSource() = NoticeNotInSource;

  /// В ячейке нет россыпи — брать из неё нечего.
  const factory MoveNotice.noLoose() = NoticeNoLoose;

  /// Короб пуст или не размещён — брать из него нечего.
  const factory MoveNotice.boxEmpty() = NoticeBoxEmpty;

  /// Ярлык недействителен: такого короба нет на сервере.
  const factory MoveNotice.labelInvalid() = NoticeLabelInvalid;

  /// Короба нет в снимке терминала, а связи нет — проверить нечем.
  const factory MoveNotice.boxUnknownOffline() = NoticeBoxUnknownOffline;

  /// Ячейка приёмки: из неё и в неё двигают заданием на размещение.
  const factory MoveNotice.receivingCell() = NoticeReceivingCell;

  /// Ячейка другого склада.
  const factory MoveNotice.foreignCell() = NoticeForeignCell;

  /// Короб уже в этой ячейке.
  const factory MoveNotice.sameCell() = NoticeSameCell;

  /// Товар кладут туда же, откуда взяли.
  const factory MoveNotice.samePlace() = NoticeSamePlace;

  /// В руках короб, отсканирован другой короб: короб в короб не кладётся.
  const factory MoveNotice.boxIntoBox() = NoticeBoxIntoBox;

  /// Товар другого склада в короб не кладётся: брак — только в короб брака (P6-07-2).
  const factory MoveNotice.warehouseMismatch() = NoticeWarehouseMismatch;

  /// Перемещено — куда.
  const factory MoveNotice.moved(String address) = NoticeMoved;
}

/// Состояние экрана перемещения (P6-04).
///
/// Сеанс: взял (короб, товар из короба или из россыпи) → положил (ячейка или короб) → … →
/// «Завершить». Всё копится на терминале и уходит одной операцией `movement_submit`.
@freezed
abstract class MovementState with _$MovementState {
  const factory MovementState({
    /// Идентификатор документа движения. Выдаёт терминал: сеанс идёт и без связи.
    String? movementId,

    /// Склад сеанса — склад первой отсканированной ячейки или короба.
    String? warehouseId,
    @Default(<MoveLine>[]) List<MoveLine> lines,
    MoveHold? hold,
    @Default(false) bool busy,
    MoveOutcome? outcome,
    String? rejectReason,
    MoveNotice? notice,
  }) = _MovementState;

  const MovementState._();

  /// Сколько товара партии [productionDate] склада [warehouseId] есть в источнике сейчас:
  /// состав на момент скана плюс то, что сеанс в этот источник положил, минус то, что из него
  /// уже взял. Брак и основной товар одной партии считаются раздельно (P6-07-2).
  double available(
    HoldSource source,
    String goodId,
    String productionDate, {
    String? warehouseId,
  }) {
    final base = source.contents
        .where(
          (c) =>
              c.goodId == goodId &&
              c.productionDate == productionDate &&
              c.internalWarehouseId == warehouseId,
        )
        .fold<double>(0, (s, c) => s + c.qty);
    var delta = 0.0;
    for (final l in lines) {
      if (l.isWholeBox ||
          l.good?.id != goodId ||
          l.productionDate != productionDate ||
          l.internalWarehouseId != warehouseId) {
        continue;
      }
      if (l.to.samePlace(source.place)) delta += l.qty ?? 0;
      if (l.from.samePlace(source.place)) delta -= l.qty ?? 0;
    }
    return _round(base + delta);
  }

  /// Что можно взять из источника: товар и партия с доступным количеством больше нуля.
  /// [goodId] — только этот товар (после скана штрихкода).
  List<(ContentLine, double)> candidates(HoldSource source, {String? goodId}) {
    final seen = <String>{};
    final out = <(ContentLine, double)>[];
    // Товар, положенный в источник в этом сеансе, тоже можно взять обратно.
    final batches = [
      ...source.contents,
      for (final l in lines)
        if (!l.isWholeBox && l.to.samePlace(source.place))
          ContentLine(
            goodId: l.good!.id,
            goodName: l.good!.name,
            goodCode: l.good!.code,
            uom: l.good!.uom,
            productionDate: l.productionDate!,
            qty: 0,
            internalWarehouseId: l.internalWarehouseId,
            internalWarehouseName: l.internalWarehouseName,
          ),
    ];
    for (final c in batches) {
      if (goodId != null && c.goodId != goodId) continue;
      if (!seen.add(
        '${c.goodId}|${c.productionDate}|${c.internalWarehouseId}',
      )) {
        continue;
      }
      final left = available(
        source,
        c.goodId,
        c.productionDate,
        warehouseId: c.internalWarehouseId,
      );
      if (left > 0) out.add((c, left));
    }
    return out;
  }

  /// Ячейка, куда короб перенесён в этом сеансе; `null` — не переносили.
  String? boxCellInSession(String loadUnitId) {
    String? cell;
    for (final l in lines) {
      if (l.loadUnitId == loadUnitId) cell = l.to.cellId;
    }
    return cell;
  }

  /// Можно завершать: что-то перемещено, в руках пусто, отправка не идёт, сеанс не завершён.
  bool get canSubmit =>
      lines.isNotEmpty && hold == null && !busy && outcome == null;

  /// Количество — до тысячных, как numeric(20,3) на сервере.
  static double _round(double q) => (q * 1000).roundToDouble() / 1000;
}
