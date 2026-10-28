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
import 'problem_marks.dart';
import 'problem_photos.dart';

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
    this.onResolve,
  });

  final PortalProblem problem;

  /// Идёт проведение решения — кнопка ждёт.
  final bool busy;

  /// «Провести»; `null` — у должности нет права решать (ADHOC-50), кнопки нет.
  final VoidCallback? onResolve;

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
              if (!p.resolved && onResolve != null) ...[
                AppBoxes.kWidth16,
                NeumorphicTextButton(
                  label: t.portal.problems.resolve,
                  accent: true,
                  busy: busy,
                  onPressed: onResolve!,
                ),
              ],
            ],
          ),
          AppBoxes.kHeight12,
          // Товар построчно: наименование, партия, количество, ячейка — как на ТСД.
          for (final it in p.items) ...[
            Text(
              it.goodName,
              style: SemiboldTextStyles().semiboldInter14.copyWith(
                color: AppColors.kTextMain,
              ),
            ),
            Text(
              t.portal.problems.itemBatch(date: isoToRu(it.productionDate)),
              style: muted,
            ),
            Text(t.portal.problems.itemQty(qty: fmtQty(it.qty)), style: muted),
            Text(
              t.portal.problems.itemCell(cell: it.cellAddress),
              style: muted,
            ),
            AppBoxes.kHeight8,
          ],
          // Марки ЧЗ — с копированием: «не наша марка» офис проверяет по самой марке (ADHOC-52).
          if (_marks(p).isNotEmpty) ...[
            ProblemMarks(marks: _marks(p)),
            AppBoxes.kHeight8,
          ],
          // Пересорт (ADHOC-53): с какого товара ушли марки и по какому ШК; складов у него нет.
          if (p.fromGood.isNotEmpty)
            Text(t.portal.problems.regradeFrom(name: p.fromGood), style: muted),
          if (p.barcode.isNotEmpty)
            Text(
              t.portal.problems.regradeBarcode(barcode: p.barcode),
              style: muted,
            ),
          if (p.fromWarehouse.isNotEmpty)
            Text(
              t.portal.problems.warehouses(
                from: p.fromWarehouse,
                to: p.toWarehouse,
              ),
              style: muted,
            ),
          if (p.comment.isNotEmpty)
            Text(t.portal.problems.comment(text: p.comment), style: muted),
          Text(
            t.portal.problems.reported(
              name: p.createdBy,
              time: fullDateTime(p.createdAt),
            ),
            style: muted,
          ),
          // Фото со склада (ADHOC-45) — офис видит брак, прежде чем решить.
          if (p.photos.isNotEmpty) ...[
            AppBoxes.kHeight12,
            Text(t.portal.problems.photos, style: main),
            AppBoxes.kHeight8,
            ProblemPhotos(problemId: p.id, photos: p.photos),
          ],
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

  /// Марки проблемы: привязанные к ней (CZ-06), а без них — введённая текстом до CZ-06.
  ///
  /// Текстовое поле при привязанных не показываем: у короба ЧЗ из прихода там код короба,
  /// а не марка.
  List<String> _marks(PortalProblem p) =>
      p.marks.isNotEmpty ? p.marks : [if (p.mark.isNotEmpty) p.mark];

  /// Принятое решение одной строкой: документ списания или пересортицы, размещение или задание возврата.
  String _decisionText(PortalProblem p) => switch (p.decision) {
    ProblemDecision.writeOff => t.portal.problems.resolvedWriteOff(
      number: p.docNumber,
      date: isoToRu(p.docDate),
    ),
    ProblemDecision.regrade => t.portal.problems.resolvedRegrade(
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
