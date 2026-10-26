import 'package:flutter/material.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';
import '../../../data/stocktakes_repository.dart';
import '../common/neumorphic_plate.dart';
import '../common/neumorphic_text_button.dart';
import 'stocktake_labels.dart';

/// Карточка пересчёта (P10-05): номер, статус, область, кто завёл, ход; кнопки «Ход» и
/// «Закрыть» (у незакрытого). Каждый факт — своей строкой.
class StocktakeCard extends StatelessWidget {
  const StocktakeCard({
    super.key,
    required this.stocktake,
    required this.busy,
    required this.onProgress,
    this.onClose,
  });

  final PortalStocktake stocktake;

  /// Идёт закрытие — кнопка ждёт.
  final bool busy;
  final VoidCallback onProgress;

  /// «Закрыть»; `null` — у должности нет права заводить и закрывать (ADHOC-50).
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final s = stocktake;
    final muted = RegularTextStyles().regularInter14.copyWith(
      color: AppColors.kTextMuted,
    );
    return NeumorphicPlate(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: AppSizes.kChipSpacing,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                t.portal.stocktake.title(number: s.number),
                style: SemiboldTextStyles().semiboldInter16.copyWith(
                  color: AppColors.kTextMain,
                ),
              ),
              Text(stocktakeStatusLabel(s.status), style: muted),
            ],
          ),
          AppBoxes.kHeight8,
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
            t.portal.stocktake.progress(counted: s.counted, total: s.cells),
            style: muted,
          ),
          AppBoxes.kHeight16,
          Wrap(
            spacing: AppSizes.kChipSpacing,
            runSpacing: AppSizes.kChipSpacing,
            children: [
              NeumorphicTextButton(
                label: t.portal.stocktake.showProgress,
                onPressed: onProgress,
              ),
              if (!s.closed && onClose != null)
                NeumorphicTextButton(
                  label: t.portal.stocktake.close,
                  accent: true,
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
