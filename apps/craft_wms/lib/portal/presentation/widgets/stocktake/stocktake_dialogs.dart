import 'package:flutter/material.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/di/injection.dart';
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

/// Подтверждение закрытия пересчёта (P10-05, плоский стиль — ADHOC-56): неподсчитанные
/// ячейки называются числом. `true` — закрыть; «Отмена» и крестик — отказ.
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

/// Ход пересчёта (P10-05, плоский стиль — ADHOC-56): ячейки — адрес, статус, кто держит.
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

  @override
  Widget build(BuildContext context) {
    final main = RegularTextStyles().regularInter13.copyWith(
      color: AppColors.kTextMain,
    );
    final head = SemiboldTextStyles().semiboldInter12.copyWith(
      color: AppColors.kTextMuted,
    );
    return FutureBuilder(
      future: getIt<StocktakesRepository>().cells(stocktakeId),
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
          },
          children: [
            TableRow(
              decoration: line,
              children: [
                cell(Text(t.portal.stocktake.colCell, style: head)),
                cell(Text(t.portal.stocktake.colStatus, style: head)),
                cell(Text(t.portal.stocktake.colWho, style: head)),
              ],
            ),
            for (final (i, c) in res.right.indexed)
              TableRow(
                decoration: i == res.right.length - 1 ? null : line,
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
                ],
              ),
          ],
        );
      },
    );
  }
}
