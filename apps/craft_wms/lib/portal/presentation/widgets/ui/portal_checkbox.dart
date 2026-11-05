import 'package:flutter/material.dart';

import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_sizes.dart';

/// Галочка портала в плоском стиле (ADHOC-57): квадрат 18 со скруглением 3.
///
/// Что: три состояния — `true` (галочка), `false` (пусто) и `null` (черта: отмечена у части
///      выборки — массовая отметка нескольких ячеек или «все показанные» в шапке списка).
/// Как: отмеченная — тёмная заливка, как главная кнопка; без [onChanged] — бледная и не
///      нажимается. Нажатие сообщает только «нажали»: что значит нажатие на черту, решает
///      владелец (обычно — поставить всем).
class PortalCheckbox extends StatelessWidget {
  const PortalCheckbox({
    super.key,
    required this.value,
    required this.onChanged,
    this.semanticLabel,
  });

  final bool? value;

  /// `null` — галочка недоступна.
  final VoidCallback? onChanged;

  /// Подпись для чтения с экрана: какую галочку нажимают.
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final on = value != false;
    final box = Container(
      width: AppSizes.kPortalCheckbox,
      height: AppSizes.kPortalCheckbox,
      decoration: BoxDecoration(
        color: on ? AppColors.kButtonPrimary : AppColors.kCardBg,
        borderRadius: AppBorders.kCircular3,
        border: Border.all(
          color: on ? AppColors.kButtonPrimary : AppColors.kTextMuted,
          width: AppSizes.kIcon2,
        ),
      ),
      child: on
          ? Icon(
              value == null ? Icons.remove : Icons.check,
              size: AppSizes.kPortalCheckboxMark,
              color: AppColors.kCardBg,
            )
          : null,
    );
    return Semantics(
      checked: value == true,
      mixed: value == null,
      enabled: onChanged != null,
      label: semanticLabel,
      child: onChanged == null
          ? Opacity(opacity: AppSizes.kDisabledOpacity, child: box)
          : MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onChanged,
                child: box,
              ),
            ),
    );
  }
}
