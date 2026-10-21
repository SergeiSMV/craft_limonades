import 'package:flutter/material.dart';

import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';
import '../../../../core/utils/date_time_format.dart';
import '../../../../core/utils/qty_format.dart';
import '../../../data/problems_repository.dart';
import '../common/neumorphic_plate.dart';
import '../common/neumorphic_text_button.dart';
import 'problem_labels.dart';

/// Карточка проблемы склада (P6-07-3): что помечено и где, почему, кто и когда; у открытой —
/// кнопка «Решить», у решённой — принятое решение.
///
/// Карточка, а не строка таблицы: у проблемы переменное число товарных строк (состав короба),
/// комментарий и решение — в колонки таблицы это не ложится.
class ProblemCard extends StatelessWidget {
  const ProblemCard({
    super.key,
    required this.problem,
    required this.busy,
    required this.onResolve,
  });

  final PortalProblem problem;

  /// Идёт проведение решения — кнопка ждёт.
  final bool busy;
  final VoidCallback onResolve;

  @override
  Widget build(BuildContext context) {
    final p = problem;
    final muted = RegularTextStyles().regularInter14.copyWith(
      color: AppColors.kTextMuted,
    );
    final main = RegularTextStyles().regularInter14.copyWith(
      color: AppColors.kTextMain,
    );
    return NeumorphicPlate(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Wrap(
                  spacing: AppSizes.kChipSpacing,
                  runSpacing: AppSizes.kChipSpacing,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      p.loadUnitId.isEmpty
                          ? t.portal.problems.goods
                          : t.portal.problems.box(code: p.loadUnitCode),
                      style: SemiboldTextStyles().semiboldInter16.copyWith(
                        color: AppColors.kTextMain,
                      ),
                    ),
                    Text(
                      t.portal.problems.cell(cell: p.cellAddress),
                      style: muted,
                    ),
                    _Pill(
                      label: reasonLabel(p.reason),
                      bg: AppColors.kBadgeInfoBg,
                      fg: AppColors.kBadgeInfoText,
                    ),
                    _Pill(
                      label: p.resolved
                          ? t.portal.problems.statusResolved
                          : t.portal.problems.statusOpen,
                      bg: p.resolved
                          ? AppColors.kBadgeSuccessBg
                          : AppColors.kBadgeWarningBg,
                      fg: p.resolved
                          ? AppColors.kBadgeSuccessText
                          : AppColors.kBadgeWarningText,
                    ),
                  ],
                ),
              ),
              if (!p.resolved) ...[
                AppBoxes.kWidth16,
                NeumorphicTextButton(
                  label: t.portal.problems.resolve,
                  accent: true,
                  busy: busy,
                  onPressed: onResolve,
                ),
              ],
            ],
          ),
          AppBoxes.kHeight12,
          for (final it in p.items)
            Padding(
              padding: AppInsets.bottom4,
              child: Text(
                t.portal.problems.item(
                  name: it.goodName,
                  date: isoToRu(it.productionDate),
                  qty: fmtQty(it.qty),
                  cell: it.cellAddress,
                ),
                style: main,
              ),
            ),
          AppBoxes.kHeight4,
          Text(
            t.portal.problems.warehouses(
              from: p.fromWarehouse,
              to: p.toWarehouse,
            ),
            style: muted,
          ),
          if (p.comment.isNotEmpty)
            Text(t.portal.problems.comment(text: p.comment), style: muted),
          if (p.mark.isNotEmpty)
            Text(t.portal.problems.mark(mark: p.mark), style: muted),
          Text(
            t.portal.problems.reported(
              name: p.createdBy,
              time: fullDateTime(p.createdAt),
            ),
            style: muted,
          ),
          if (p.resolved) ...[
            AppBoxes.kHeight12,
            Text(
              _decisionText(p),
              style: SemiboldTextStyles().semiboldInter14.copyWith(
                color: AppColors.kTextMain,
              ),
            ),
            if (p.resolvedAt != null)
              Text(
                t.portal.problems.resolvedBy(
                  name: p.resolvedBy,
                  time: fullDateTime(p.resolvedAt!),
                ),
                style: muted,
              ),
          ],
        ],
      ),
    );
  }

  /// Принятое решение одной строкой: документ списания, размещение или задание возврата.
  String _decisionText(PortalProblem p) => switch (p.decision) {
    ProblemDecision.writeOff => t.portal.problems.resolvedWriteOff(
      number: p.docNumber,
      date: isoToRu(p.docDate),
    ),
    ProblemDecision.place => t.portal.problems.resolvedPlace,
    ProblemDecision.supplierReturn => t.portal.problems.resolvedReturn(
      supplier: p.supplierName,
      number: p.returnTaskNumber,
    ),
    _ => p.decision,
  };
}

/// Отметка — пилюля, как статус документа.
class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.bg, required this.fg});

  final String label;
  final Color bg;
  final Color fg;

  @override
  Widget build(BuildContext context) => Container(
    padding: AppInsets.badge,
    decoration: BoxDecoration(color: bg, borderRadius: AppBorders.kPill),
    child: Text(
      label,
      style: SemiboldTextStyles().semiboldInter12.copyWith(color: fg),
    ),
  );
}
