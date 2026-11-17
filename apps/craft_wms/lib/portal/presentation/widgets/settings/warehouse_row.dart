import 'package:flutter/material.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';
import '../../../data/internal_warehouses_repository.dart';
import '../ui/portal_badge.dart';
import '../ui/portal_button.dart';
import '../ui/portal_checkbox.dart';

/// Строка склада: имя и код, отметки («По умолчанию», «Скрыт», «Есть остаток») и действия -
/// переименовать, скрыть или вернуть, удалить. Чего со складом сделать нельзя, того и нет.
class WarehouseRow extends StatelessWidget {
  const WarehouseRow({
    super.key,
    required this.warehouse,
    required this.busy,
    required this.onRename,
    required this.onToggle,
    required this.onTogglePicking,
    required this.onDelete,
  });

  final PortalWarehouse warehouse;

  /// Идёт действие с этим складом - кнопки ждут.
  final bool busy;
  final VoidCallback onRename;
  final VoidCallback onToggle;

  /// Разрешить или запретить сборку из склада (P8-02).
  final VoidCallback onTogglePicking;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final w = warehouse;
    return Padding(
      padding: AppInsets.cardRow,
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
                      PortalBadge(
                        t.portal.warehouses.markDefault,
                        tone: PortalBadgeTone.success,
                      ),
                    if (w.isSystem) PortalBadge(t.portal.warehouses.markSystem),
                    if (!w.isActive)
                      PortalBadge(
                        t.portal.warehouses.markHidden,
                        tone: PortalBadgeTone.warning,
                      ),
                    if (w.inUse && !w.isDefault && !w.isSystem)
                      PortalBadge(t.portal.warehouses.markInUse),
                  ],
                ),
                // Галочка «разрешить сборку» (P8-02): у системного склада её нет - из него не
                // собирают. Своей строкой под отметками: в узком окне строка не переполняется.
                if (w.canTogglePicking) ...[
                  AppBoxes.kHeight8,
                  Row(
                    children: [
                      PortalCheckbox(
                        value: w.allowPicking,
                        onChanged: busy ? null : onTogglePicking,
                        semanticLabel: t.portal.warehouses.allowPicking,
                      ),
                      AppBoxes.kWidth8,
                      Flexible(
                        child: Text(
                          t.portal.warehouses.allowPicking,
                          style: RegularTextStyles().regularInter13.copyWith(
                            color: AppColors.kTextMain,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          AppBoxes.kWidth8,
          PortalIconButton(
            icon: Icons.edit_outlined,
            tooltip: t.portal.warehouses.rename,
            busy: busy,
            onPressed: onRename,
          ),
          if (w.canToggle) ...[
            AppBoxes.kWidth4,
            PortalIconButton(
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
            AppBoxes.kWidth4,
            PortalIconButton(
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
