import 'package:flutter/material.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/gen/strings.g.dart';
import 'portal_button.dart';
import 'portal_modal.dart';

/// Выбор даты в портале (ADHOC-30, плоский стиль — ADHOC-56): сетка месяца в [PortalModal],
/// по-русски и в цветах портала — вместо стандартного `showDatePicker` с его темой и шапкой.
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
      return PortalModal(
        title: title,
        content: Center(
          child: SizedBox(
            width: AppSizes.kPortalCalendarWidth,
            height: AppSizes.kPortalCalendarHeight,
            // Сетка берёт цвета из схемы темы: выбранный день — тёмный, как главная кнопка.
            child: Theme(
              data: theme.copyWith(
                colorScheme: theme.colorScheme.copyWith(
                  primary: AppColors.kButtonPrimary,
                  onPrimary: AppColors.kCardBg,
                  surface: AppColors.kCardBg,
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
        ),
        actions: [
          portalCancel(ctx, label: t.portal.common.cancel),
          PortalButton(
            label: t.portal.common.choose,
            kind: PortalButtonKind.primary,
            onPressed: () => Navigator.of(ctx).pop(picked),
          ),
        ],
      );
    },
  );
}
