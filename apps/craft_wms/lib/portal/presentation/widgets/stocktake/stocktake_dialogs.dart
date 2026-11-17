import 'package:either_dart/either.dart';
import 'package:flutter/material.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/error/failure.dart';
import '../../../../core/load_unit/box_code.dart';
import '../../../../core/utils/qty_format.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';
import '../../../../core/utils/doc_number.dart';
import '../../../data/stocktakes_repository.dart';
import '../settings/access_common.dart';
import '../ui/portal_badge.dart';
import '../ui/portal_button.dart';
import '../ui/portal_modal.dart';
import 'stocktake_labels.dart';

/// Подтверждение закрытия пересчёта (P10-05, плоский стиль - ADHOC-56): неподсчитанные
/// ячейки называются числом. `true` - закрыть; «Отмена» и крестик - отказ.
Future<bool> showStocktakeCloseDialog(
  BuildContext context,
  PortalStocktake s,
) async {
  final uncounted = s.cells - s.counted;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => PortalModal(
      title: t.portal.stocktake.closeTitle(
        number: docNumber(DocKind.stocktake, s.number),
      ),
      content: Text(
        uncounted == 0
            ? t.portal.stocktake.closeBodyAll
            : t.portal.stocktake.closeBodyUncounted(count: uncounted),
        style: RegularTextStyles().regularInter13.copyWith(
          color: AppColors.kTextMain,
        ),
      ),
      actions: [
        portalCancel(ctx, label: t.portal.stocktake.cancel, result: false),
        PortalButton(
          label: t.portal.stocktake.closeYes,
          kind: PortalButtonKind.primary,
          onPressed: () => Navigator.of(ctx).pop(true),
        ),
      ],
    ),
  );
  return ok ?? false;
}

/// Ход пересчёта (P10-05, плоский стиль - ADHOC-56): ячейки - адрес, статус, кто держит.
/// Длинный список прокручивается в окне, шапка и подвал окна остаются на месте.
Future<void> showStocktakeProgressDialog(
  BuildContext context,
  PortalStocktake s,
) => showDialog<void>(
  context: context,
  builder: (ctx) => PortalModal(
    title: t.portal.stocktake.progressTitle(
      number: docNumber(DocKind.stocktake, s.number),
    ),
    maxWidth: AppSizes.kPortalDialogWideWidth,
    content: _ProgressTable(stocktakeId: s.id),
    actions: [
      PortalButton(
        label: t.portal.stocktake.closeDialog,
        onPressed: () => Navigator.of(ctx).pop(),
      ),
    ],
  ),
);

class _ProgressTable extends StatelessWidget {
  const _ProgressTable({required this.stocktakeId});

  final String stocktakeId;

  /// Ячейки и строки пересчёта разом; не вышло одно - ошибка окна.
  Future<
    Either<Failure, (List<PortalStocktakeCell>, List<PortalStocktakeLine>)>
  >
  _load() async {
    final repo = getIt<StocktakesRepository>();
    final (cells, lines) = await (
      repo.cells(stocktakeId),
      repo.lines(stocktakeId),
    ).wait;
    if (cells.isLeft) return Left(cells.left);
    if (lines.isLeft) return Left(lines.left);
    return Right((cells.right, lines.right));
  }

  /// Что в ячейке: по строке - товар (партия) или короб, ожидалось и посчитано. Подсчитанная без
  /// строк - ничего не ожидалось и не найдено; не подсчитанная - прочерк.
  static List<String> _cellLines(
    String address,
    String status,
    List<PortalStocktakeLine> lines,
  ) {
    final s = t.portal.stocktake;
    final own = lines.where((l) => l.cell == address).toList();
    if (status != 'counted') {
      return [
        for (final l in own)
          s.lineExpected(what: _what(l), qty: _qty(l.expected, l)),
      ];
    }
    if (own.isEmpty) return [s.lineNothing];
    return [
      for (final l in own)
        s.lineCounted(
              what: _what(l),
              expected: _qty(l.expected, l),
              fact: _qty(l.fact ?? 0, l),
            ) +
            (l.problem ? s.lineProblem : ''),
    ];
  }

  static String _what(PortalStocktakeLine l) {
    final s = t.portal.stocktake;
    if (l.goodName.isEmpty) return s.lineBox(code: boxCode(l.loadUnitId));
    if (l.productionDate.isEmpty) return l.goodName;
    final p = l.productionDate.split('-');
    final date = p.length == 3 ? '${p[2]}.${p[1]}.${p[0]}' : l.productionDate;
    return s.lineGood(name: l.goodName, date: date);
  }

  static String _qty(double v, PortalStocktakeLine l) =>
      l.goodName.isEmpty ? fmtQty(v) : '${fmtQty(v)} ${l.uom}';

  @override
  Widget build(BuildContext context) {
    final main = RegularTextStyles().regularInter13.copyWith(
      color: AppColors.kTextMain,
    );
    final head = SemiboldTextStyles().semiboldInter12.copyWith(
      color: AppColors.kTextMuted,
    );
    return FutureBuilder(
      future: _load(),
      builder: (context, snap) {
        final res = snap.data;
        if (res == null) {
          return Text(
            t.portal.stocktake.loading,
            style: main.copyWith(color: AppColors.kTextMuted),
          );
        }
        if (res.isLeft) {
          return AccessError(
            t.portal.stocktake.error(message: stocktakeErrorText(res.left)),
          );
        }
        const line = BoxDecoration(
          border: Border(bottom: BorderSide(color: AppColors.kDivider)),
        );
        Widget cell(Widget child) =>
            Padding(padding: AppInsets.v8, child: child);
        return Table(
          defaultVerticalAlignment: TableCellVerticalAlignment.middle,
          columnWidths: const {
            0: FlexColumnWidth(2),
            1: FlexColumnWidth(2),
            2: FlexColumnWidth(3),
            3: FlexColumnWidth(6),
          },
          children: [
            TableRow(
              decoration: line,
              children: [
                cell(Text(t.portal.stocktake.colCell, style: head)),
                cell(Text(t.portal.stocktake.colStatus, style: head)),
                cell(Text(t.portal.stocktake.colWho, style: head)),
                cell(Text(t.portal.stocktake.colLines, style: head)),
              ],
            ),
            for (final (i, c) in res.right.$1.indexed)
              TableRow(
                decoration: i == res.right.$1.length - 1 ? null : line,
                children: [
                  cell(Text(c.address, style: main)),
                  cell(
                    Align(
                      alignment: Alignment.centerLeft,
                      child: PortalBadge(
                        cellStatusLabel(c.status),
                        tone: cellStatusTone(c.status),
                      ),
                    ),
                  ),
                  cell(Text(c.takenBy, style: main)),
                  cell(
                    Text(
                      _cellLines(c.address, c.status, res.right.$2).join('\n'),
                      style: main,
                    ),
                  ),
                ],
              ),
          ],
        );
      },
    );
  }
}
