import 'package:flutter/material.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';
import '../ui/portal_checkbox.dart';

/// Строка вида PDF окна печати (ADHOC-57): галочка, название и размер, справа — сколько штук
/// и листов. Печатать нечего ([count] = 0) — галочка снята и недоступна.
class PrintKindRow extends StatelessWidget {
  const PrintKindRow({
    super.key,
    required this.title,
    required this.hint,
    required this.count,
    required this.perSheet,
    required this.selected,
    required this.onToggle,
  });

  final String title;
  final String hint;
  final int count;

  /// Этикеток или карточек на листе A4.
  final int perSheet;
  final bool selected;

  /// `null` — переключать нельзя (идёт скачивание).
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) {
    final s = t.portal.cells.printDialog;
    final sheets = (count + perSheet - 1) ~/ perSheet;
    final muted = RegularTextStyles().regularInter12.copyWith(
      color: AppColors.kTextMuted,
    );
    final onTap = count > 0 ? onToggle : null;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: AppInsets.cardRow,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            PortalCheckbox(
              value: count > 0 && selected,
              onChanged: onTap,
              semanticLabel: title,
            ),
            AppBoxes.kWidth12,
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: SemiboldTextStyles().semiboldInter13.copyWith(
                      color: AppColors.kTextMain,
                    ),
                  ),
                  Text(hint, style: muted),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  s.count(count: count),
                  style: RegularTextStyles().regularInter13.copyWith(
                    color: AppColors.kTextSecondary,
                  ),
                ),
                Text(
                  count > 0 ? s.sheets(count: sheets) : s.none,
                  style: muted,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
