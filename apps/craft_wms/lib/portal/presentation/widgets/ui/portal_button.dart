import 'package:flutter/material.dart';

import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/theme/semibold_text.dart';

/// Вид кнопки портала: главная — тёмная заливка, обычная — белая с рамкой, текстовая — без фона.
enum PortalButtonKind { primary, secondary, plain }

/// Кнопка с подписью в плоском стиле (ADHOC-56, по Shopify Polaris).
///
/// Что: «Добавить», «Сохранить», «Отмена» — высота 32, подпись 13.
/// Как: главное действие экрана или диалога — [PortalButtonKind.primary], одно на место;
///      остальные — [PortalButtonKind.secondary]; отмена — [PortalButtonKind.plain]. Пока
///      действие идёт ([busy]), вместо иконки — индикатор, и кнопка не нажимается.
class PortalButton extends StatelessWidget {
  const PortalButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.kind = PortalButtonKind.secondary,
    this.icon,
    this.busy = false,
  });

  final String label;
  final VoidCallback onPressed;
  final PortalButtonKind kind;

  /// Иконка перед подписью; `null` — только подпись.
  final IconData? icon;

  /// Действие идёт — индикатор на месте иконки, кнопка не нажимается.
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final (bg, fg, border, hover) = switch (kind) {
      PortalButtonKind.primary => (
        AppColors.kButtonPrimary,
        AppColors.kCardBg,
        AppColors.kButtonPrimary,
        AppColors.kButtonPrimaryHover,
      ),
      PortalButtonKind.secondary => (
        AppColors.kCardBg,
        AppColors.kTextMain,
        AppColors.kInputBorder,
        AppColors.kBg,
      ),
      PortalButtonKind.plain => (
        Colors.transparent,
        AppColors.kTextSecondary,
        Colors.transparent,
        AppColors.kBg,
      ),
    };
    return SizedBox(
      height: AppSizes.kControlHeight,
      child: Material(
        color: bg,
        shape: RoundedRectangleBorder(
          borderRadius: AppBorders.kCircular8,
          side: BorderSide(color: border),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: busy ? null : onPressed,
          hoverColor: hover,
          child: Padding(
            padding: AppInsets.button,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (busy)
                  SizedBox.square(
                    dimension: AppSizes.kIcon16,
                    child: CircularProgressIndicator(
                      strokeWidth: AppSizes.kIcon2,
                      color: fg,
                    ),
                  )
                else if (icon != null)
                  Icon(icon, size: AppSizes.kIcon16, color: fg),
                if (busy || icon != null) AppBoxes.kWidth4,
                // В узкой колонке подпись сокращается, а не выталкивает кнопку за край.
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: SemiboldTextStyles().semiboldInter13.copyWith(
                      color: fg,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Кнопка-иконка без подложки (ADHOC-56): действие строки списка, меню и выход в шапке.
/// Подсветка — только при наведении; подпись действия — во всплывающей подсказке.
class PortalIconButton extends StatelessWidget {
  const PortalIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.busy = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  /// Действие идёт — индикатор вместо иконки.
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: SizedBox.square(
        dimension: AppSizes.kControlHeight,
        child: Material(
          color: Colors.transparent,
          shape: const RoundedRectangleBorder(
            borderRadius: AppBorders.kCircular8,
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: busy ? null : onPressed,
            hoverColor: AppColors.kBorder,
            child: Center(
              child: busy
                  ? const SizedBox.square(
                      dimension: AppSizes.kIcon16,
                      child: CircularProgressIndicator(
                        strokeWidth: AppSizes.kIcon2,
                      ),
                    )
                  : Icon(
                      icon,
                      size: AppSizes.kIcon18,
                      color: AppColors.kTextMuted,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
