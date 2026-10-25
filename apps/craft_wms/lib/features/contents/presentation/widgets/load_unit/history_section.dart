import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../../core/constants/app_boxes.dart';
import '../../../../../core/constants/app_colors.dart';
import '../../../../../core/constants/app_insets.dart';
import '../../../../../core/constants/app_sizes.dart';
import '../../../../../core/error/failure.dart';
import '../../../../../core/gen/strings.g.dart';
import '../../../../../core/theme/regular_text.dart';
import '../../../../../core/theme/semibold_text.dart';
import '../../../../../core/printer/load_unit_label.dart';
import '../../../../../core/utils/date_time_format.dart';
import '../../../../../core/utils/qty_format.dart';
import '../../../../../core/widgets/expandable_card.dart';
import '../../../domain/contents_entities.dart';
import '../../bloc/load_unit_history_cubit.dart';
import '../common/contents_message.dart';

/// Блок «История» карточки короба (P5-05-1, ADHOC-32): приёмка, переносы и изменения состава —
/// что доложили и что вынули. Только со связью — без неё
/// блок так и говорит, остальная карточка при этом из снимка.
///
/// Раскрывающаяся плашка, свёрнутая по умолчанию, — как «Штрихкоды» в карточке товара:
/// у короба, который много переносили, история длиннее всего остального на экране и
/// оттесняла бы вниз содержимое — то, ради чего карточку открывают.
class HistorySection extends StatelessWidget {
  const HistorySection({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<LoadUnitHistoryCubit>().state;
    final title = switch (state) {
      HistoryLoaded(:final history) => t.contents.historyTitleCount(
        count: history.moves.length + history.contents.length,
      ),
      _ => t.contents.historyTitle,
    };
    return Padding(
      padding: AppInsets.top8,
      child: ExpandableCard(
        headerBuilder: (_) => Padding(
          padding: AppInsets.top4,
          child: Text(
            title,
            style: SemiboldTextStyles().semiboldInter14.copyWith(
              color: AppColors.kTextMain,
            ),
          ),
        ),
        child: switch (state) {
          HistoryLoading() => const Padding(
            padding: AppInsets.all16,
            child: Center(
              child: SizedBox(
                width: AppSizes.kIcon18,
                height: AppSizes.kIcon18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ),
          HistoryFailed(failure: NetworkFailure()) => ContentsMessage(
            text: t.contents.historyOnlineOnly,
          ),
          HistoryFailed() => ContentsMessage(text: t.contents.historyFailed),
          HistoryLoaded(:final history) => _History(history: history),
        },
      ),
    );
  }
}

/// История по порядку: создание, приёмка, затем переносы и изменения состава вперемешку —
/// по времени, как это происходило на складе.
class _History extends StatelessWidget {
  const _History({required this.history});

  final LoadUnitHistory history;

  @override
  Widget build(BuildContext context) {
    final receipt = history.receipt;
    // Отступы как у строк «Штрихкодов»: тело раскрывается внутри той же плашки, что и шапка.
    return Padding(
      padding: AppInsets.h16 + AppInsets.bottom16,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _line(
            t.contents.historyCreated(time: fullDateTime(history.createdAt)),
          ),
          if (receipt != null) ...[
            if (receipt.docNumber != null && receipt.docDate != null)
              _muted(
                t.contents.historyDoc(
                  number: receipt.docNumber!,
                  date: batchDate(receipt.docDate!),
                ),
              ),
            _muted(t.contents.historyReceived(name: receipt.receivedBy)),
            _muted(
              receipt.supplier == null
                  ? t.contents.historyNoSupplier
                  : t.contents.historySupplier(name: receipt.supplier!),
            ),
            if (receipt.postedAt == null) _muted(t.contents.historyNotPosted),
          ],
          for (final e in _timeline()) ...[
            AppBoxes.kHeight8,
            ...switch (e) {
              LoadUnitMove() => _move(e),
              LoadUnitContentChange() => _content(e),
              _ => const <Widget>[],
            },
          ],
        ],
      ),
    );
  }

  /// Переносы и изменения состава одной лентой по времени; при равном времени перенос
  /// раньше — короб сначала встал на место, потом с ним работали.
  List<Object> _timeline() {
    final all = <(DateTime, int, Object)>[
      for (final m in history.moves) (m.at, 0, m),
      for (final c in history.contents) (c.at, 1, c),
    ];
    all.sort((a, b) {
      final byTime = a.$1.compareTo(b.$1);
      return byTime != 0 ? byTime : a.$2 - b.$2;
    });
    return [for (final e in all) e.$3];
  }

  /// Перенос короба: откуда → куда, кто и когда.
  List<Widget> _move(LoadUnitMove m) => [
    _line(switch ((m.kind, m.from)) {
      (LoadUnitMoveKind.stockEntry, _) => t.contents.moveStockEntry(to: m.to),
      (LoadUnitMoveKind.receipt, _) ||
      (_, null) => t.contents.moveReceipt(to: m.to),
      (LoadUnitMoveKind.putaway, final from?) => t.contents.movePutaway(
        from: from,
        to: m.to,
      ),
      (LoadUnitMoveKind.move, final from?) => t.contents.moveMove(
        from: from,
        to: m.to,
      ),
      (LoadUnitMoveKind.other, final from?) => t.contents.moveOther(
        from: from,
        to: m.to,
      ),
    }),
    _by(m.userName, m.at),
  ];

  /// Изменение состава: что произошло и сколько, построчно — товар с партией, кто и когда.
  List<Widget> _content(LoadUnitContentChange c) {
    final qty = fmtQty(c.qty);
    final box = c.peerLoadUnitId == null
        ? null
        : LoadUnitLabel(c.peerLoadUnitId!).shortCodeFormatted;
    final peer = c.peer ?? '';
    return [
      _line(switch (c.kind) {
        LoadUnitContentKind.added =>
          box == null
              ? t.contents.contentAdded(qty: qty, uom: c.uom, from: peer)
              : t.contents.contentAddedBox(
                  qty: qty,
                  uom: c.uom,
                  box: box,
                  from: peer,
                ),
        LoadUnitContentKind.removed =>
          box == null
              ? t.contents.contentRemoved(qty: qty, uom: c.uom, to: peer)
              : t.contents.contentRemovedBox(
                  qty: qty,
                  uom: c.uom,
                  box: box,
                  to: peer,
                ),
        LoadUnitContentKind.problem => t.contents.contentProblem(
          qty: qty,
          uom: c.uom,
          cell: peer,
        ),
        LoadUnitContentKind.writtenOff => t.contents.contentWrittenOff(
          qty: qty,
          uom: c.uom,
        ),
        LoadUnitContentKind.returned => t.contents.contentReturned(
          qty: qty,
          uom: c.uom,
        ),
        LoadUnitContentKind.other => t.contents.contentOther(
          qty: qty,
          uom: c.uom,
        ),
      }),
      _muted(
        t.contents.contentGood(
          name: c.goodName,
          date: batchDate(c.productionDate),
        ),
      ),
      _by(c.userName, c.at),
    ];
  }

  /// Кто и когда.
  Widget _by(String? name, DateTime at) => _muted(
    name == null
        ? t.contents.moveByUnknown(time: fullDateTime(at))
        : t.contents.moveBy(name: name, time: fullDateTime(at)),
  );

  Widget _line(String text) => Text(
    text,
    style: SemiboldTextStyles().semiboldInter14.copyWith(
      color: AppColors.kSidebarHover,
    ),
  );

  Widget _muted(String text) => Text(
    text,
    style: RegularTextStyles().regularInter12.copyWith(
      color: AppColors.kTextMuted,
    ),
  );
}
