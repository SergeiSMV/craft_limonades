import 'package:flutter/material.dart';

import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';
import '../../../data/internal_warehouses_repository.dart';
import '../common/neumorphic_icon_button.dart';

/// Строка склада: имя и код, отметки («По умолчанию», «Скрыт», «Есть остаток») и действия —
/// переименовать, скрыть или вернуть, удалить. Чего со складом сделать нельзя, того и нет.
class WarehouseRow extends StatelessWidget {
  const WarehouseRow({
    super.key,
    required this.warehouse,
    required this.busy,
    required this.onRename,
    required this.onToggle,
    required this.onDelete,
  });

  final PortalWarehouse warehouse;

  /// Идёт действие с этим складом — кнопки ждут.
  final bool busy;
  final VoidCallback onRename;
  final VoidCallback onToggle;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final w = warehouse;
    return Padding(
      padding: AppInsets.v8,
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  w.name,
                  style: SemiboldTextStyles().semiboldInter14.copyWith(
                    color: w.isActive
                        ? AppColors.kTextMain
                        : AppColors.kTextMuted,
                  ),
                ),
                AppBoxes.kHeight4,
                Wrap(
                  spacing: AppSizes.kChipSpacing,
                  runSpacing: AppSizes.kChipSpacing,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      w.code,
                      style: RegularTextStyles().regularInter12.copyWith(
                        color: AppColors.kTextMuted,
                      ),
                    ),
                    if (w.isDefault)
                      _Mark(
                        label: t.portal.warehouses.markDefault,
                        bg: AppColors.kBadgeSuccessBg,
                        fg: AppColors.kBadgeSuccessText,
                      ),
                    if (w.isSystem)
                      _Mark(
                        label: t.portal.warehouses.markSystem,
                        bg: AppColors.kBorder,
                        fg: AppColors.kTextMuted,
                      ),
                    if (!w.isActive)
                      _Mark(
                        label: t.portal.warehouses.markHidden,
                        bg: AppColors.kBadgeWarningBg,
                        fg: AppColors.kBadgeWarningText,
                      ),
                    if (w.inUse && !w.isDefault && !w.isSystem)
                      _Mark(
                        label: t.portal.warehouses.markInUse,
                        bg: AppColors.kBorder,
                        fg: AppColors.kTextMuted,
                      ),
                  ],
                ),
              ],
            ),
          ),
          AppBoxes.kWidth8,
          NeumorphicIconButton(
            icon: Icons.edit_outlined,
            tooltip: t.portal.warehouses.rename,
            busy: busy,
            onPressed: onRename,
          ),
          if (w.canToggle) ...[
            AppBoxes.kWidth12,
            NeumorphicIconButton(
              icon: w.isActive
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
              tooltip: w.isActive
                  ? t.portal.warehouses.hide
                  : t.portal.warehouses.show,
              busy: busy,
              onPressed: onToggle,
            ),
          ],
          if (w.canDelete) ...[
            AppBoxes.kWidth12,
            NeumorphicIconButton(
              icon: Icons.delete_outline,
              tooltip: t.portal.warehouses.delete,
              busy: busy,
              onPressed: onDelete,
            ),
          ],
        ],
      ),
    );
  }
}

/// Отметка склада — пилюля, как статус документа.
class _Mark extends StatelessWidget {
  const _Mark({required this.label, required this.bg, required this.fg});

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
