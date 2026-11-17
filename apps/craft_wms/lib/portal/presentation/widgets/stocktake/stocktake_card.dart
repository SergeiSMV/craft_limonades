import 'package:flutter/material.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';
import '../../../../core/utils/doc_number.dart';
import '../../../domain/stocktakes/stocktakes_repository.dart';
import '../ui/portal_badge.dart';
import '../ui/portal_button.dart';
import 'stocktake_labels.dart';

/// Строка пересчёта в карточке списка (P10-05, плоский стиль - ADHOC-56): номер со статусом,
/// область, кто завёл, когда закрыт, ход - каждый факт своей строкой; справа «Ход» и
/// «Закрыть» (у незакрытого).
class StocktakeCard extends StatelessWidget {
  const StocktakeCard({
    super.key,
    required this.stocktake,
    required this.busy,
    required this.onProgress,
    this.onClose,
  });

  final PortalStocktake stocktake;

  /// Идёт закрытие - кнопка ждёт.
  final bool busy;
  final VoidCallback onProgress;

  /// «Закрыть»; `null` - у должности нет права заводить и закрывать (ADHOC-50).
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final s = stocktake;
    final muted = RegularTextStyles().regularInter12.copyWith(
      color: AppColors.kTextSecondary,
    );
    return Padding(
      padding: AppInsets.cardRow,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: AppSizes.kChipSpacing,
                  runSpacing: AppSizes.kChipSpacing,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      t.portal.stocktake.title(
                        number: docNumber(DocKind.stocktake, s.number),
                      ),
                      style: SemiboldTextStyles().semiboldInter13.copyWith(
                        color: AppColors.kTextMain,
                      ),
                    ),
                    PortalBadge(
                      stocktakeStatusLabel(s.status),
                      tone: stocktakeStatusTone(s.status),
                    ),
                  ],
                ),
                AppBoxes.kHeight4,
                Text(
                  t.portal.stocktake.scope(scope: scopeLabel(s.scopeKind)),
                  style: muted,
                ),
                Text(
                  t.portal.stocktake.created(
                    name: s.createdBy,
                    date: portalDateTime(s.createdAt),
                  ),
                  style: muted,
                ),
                if (s.closedAt case final at?)
                  Text(
                    t.portal.stocktake.closedAt(date: portalDateTime(at)),
                    style: muted,
                  ),
                Text(
                  t.portal.stocktake.progress(
                    counted: s.counted,
                    total: s.cells,
                  ),
                  style: muted,
                ),
              ],
            ),
          ),
          AppBoxes.kWidth8,
          Wrap(
            spacing: AppSizes.kChipSpacing,
            runSpacing: AppSizes.kChipSpacing,
            alignment: WrapAlignment.end,
            children: [
              PortalButton(
                label: t.portal.stocktake.showProgress,
                onPressed: onProgress,
              ),
              if (!s.closed && onClose != null)
                PortalButton(
                  label: t.portal.stocktake.close,
                  busy: busy,
                  onPressed: onClose!,
                ),
            ],
          ),
        ],
      ),
    );
  }
}
