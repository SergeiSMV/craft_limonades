import 'package:flutter/material.dart';

import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';
import '../../../data/stocktakes_repository.dart';
import '../common/neumorphic_text_button.dart';
import '../common/portal_dialog.dart';
import 'stocktake_labels.dart';

/// Подтверждение закрытия пересчёта (P10-05): неподсчитанные ячейки называются числом.
/// `true` — закрыть.
Future<bool> showStocktakeCloseDialog(
  BuildContext context,
  PortalStocktake s,
) async {
  final uncounted = s.cells - s.counted;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => PortalDialog(
      title: t.portal.stocktake.closeTitle(number: s.number),
      content: Text(
        uncounted == 0
            ? t.portal.stocktake.closeBodyAll
            : t.portal.stocktake.closeBodyUncounted(count: uncounted),
        style: RegularTextStyles().regularInter14.copyWith(
          color: AppColors.kTextMain,
        ),
      ),
      actions: [
        TextButton(
          style: TextButton.styleFrom(foregroundColor: AppColors.kTextMuted),
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(t.portal.stocktake.cancel),
        ),
        NeumorphicTextButton(
          label: t.portal.stocktake.closeYes,
          accent: true,
          onPressed: () => Navigator.of(ctx).pop(true),
        ),
      ],
    ),
  );
  return ok ?? false;
}

/// Ход пересчёта (P10-05): ячейки — адрес, статус, кто держит.
Future<void> showStocktakeProgressDialog(
  BuildContext context,
  PortalStocktake s,
) => showDialog<void>(
  context: context,
  builder: (ctx) => PortalDialog(
    title: t.portal.stocktake.progressTitle(number: s.number),
    content: SizedBox(
      width: AppSizes.kPortalDialogWidth,
      child: _ProgressTable(stocktakeId: s.id),
    ),
    actions: [
      NeumorphicTextButton(
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
    final main = RegularTextStyles().regularInter14.copyWith(
      color: AppColors.kTextMain,
    );
    final head = SemiboldTextStyles().semiboldInter14.copyWith(
      color: AppColors.kTextMuted,
    );
    return FutureBuilder(
      future: getIt<StocktakesRepository>().cells(stocktakeId),
      builder: (context, snap) {
        final res = snap.data;
        if (res == null) {
          return Text(t.portal.stocktake.loading, style: main);
        }
        if (res.isLeft) {
          return Text(
            t.portal.stocktake.error(message: stocktakeErrorText(res.left)),
            style: main.copyWith(color: AppColors.kDanger),
          );
        }
        return ConstrainedBox(
          constraints: const BoxConstraints(
            maxHeight: AppSizes.kPortalPickListMaxHeight,
          ),
          child: SingleChildScrollView(
            child: Table(
              columnWidths: const {
                0: FlexColumnWidth(2),
                1: FlexColumnWidth(2),
                2: FlexColumnWidth(3),
              },
              children: [
                TableRow(
                  children: [
                    Text(t.portal.stocktake.colCell, style: head),
                    Text(t.portal.stocktake.colStatus, style: head),
                    Text(t.portal.stocktake.colWho, style: head),
                  ],
                ),
                for (final c in res.right)
                  TableRow(
                    children: [
                      _cell(c.address, main),
                      _cell(cellStatusLabel(c.status), main),
                      _cell(c.takenBy, main),
                    ],
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _cell(String text, TextStyle style) => Padding(
    padding: AppInsets.top8,
    child: Text(text, style: style),
  );
}
