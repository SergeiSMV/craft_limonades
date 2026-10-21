import 'package:flutter/material.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/gen/strings.g.dart';
import 'neumorphic_text_button.dart';
import 'portal_dialog.dart';

/// Выбор даты в портале (ADHOC-30): сетка месяца в `PortalDialog` с кнопками портала, по-русски
/// и в цветах портала — вместо стандартного `showDatePicker` с его темой и шапкой.
///
/// Возвращает выбранную дату; `null` — оператор передумал.
Future<DateTime?> showPortalDatePicker(
  BuildContext context, {
  required String title,
  required DateTime initial,
  required DateTime first,
  required DateTime last,
}) {
  var picked = initial;
  return showDialog<DateTime>(
    context: context,
    builder: (ctx) {
      final theme = Theme.of(ctx);
      return PortalDialog(
        title: title,
        content: SizedBox(
          width: AppSizes.kPortalCalendarWidth,
          height: AppSizes.kPortalCalendarHeight,
          // Сетка берёт цвета из схемы темы: выбранный день — акцент портала, фон — плашка.
          child: Theme(
            data: theme.copyWith(
              colorScheme: theme.colorScheme.copyWith(
                primary: AppColors.kPrimary,
                onPrimary: AppColors.kNeumorphicLight,
                surface: AppColors.kNeumorphicBg,
                onSurface: AppColors.kTextMain,
              ),
            ),
            child: CalendarDatePicker(
              initialDate: initial,
              firstDate: first,
              lastDate: last,
              onDateChanged: (d) => picked = d,
            ),
          ),
        ),
        actions: [
          TextButton(
            style: TextButton.styleFrom(foregroundColor: AppColors.kTextMuted),
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(t.portal.common.cancel),
          ),
          NeumorphicTextButton(
            label: t.portal.common.choose,
            accent: true,
            onPressed: () => Navigator.of(ctx).pop(picked),
          ),
        ],
      );
    },
  );
}
