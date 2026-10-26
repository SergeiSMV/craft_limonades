import 'package:flutter/material.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';
import '../../../data/users_repository.dart';
import '../common/neumorphic_icon_button.dart';
import 'access_common.dart';
import 'rights_tree.dart';

/// Строка должности (ADHOC-50): название, разделы с правами по приложениям, сколько
/// пользователей; изменить и удалить.
/// «Администратор» — отметка «Все права» и без действий.
class PositionRow extends StatelessWidget {
  const PositionRow({
    super.key,
    required this.position,
    required this.busy,
    required this.onEdit,
    required this.onDelete,
  });

  final PortalPosition position;
  final bool busy;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final p = position;
    final muted = RegularTextStyles().regularInter12.copyWith(
      color: AppColors.kTextMuted,
    );
    return Padding(
      padding: AppInsets.v8,
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: AppSizes.kChipSpacing,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      p.name,
                      style: SemiboldTextStyles().semiboldInter14.copyWith(
                        color: AppColors.kTextMain,
                      ),
                    ),
                    if (p.isSystem)
                      AccessMark(
                        label: t.portal.positions.markSystem,
                        bg: AppColors.kBadgeSuccessBg,
                        fg: AppColors.kBadgeSuccessText,
                      ),
                  ],
                ),
                AppBoxes.kHeight4,
                if (!p.isSystem) ...[
                  if (p.rights.isEmpty)
                    Text(t.portal.positions.noRights, style: muted),
                  for (final line in rightsSummary(p.rights))
                    Text(line, style: muted),
                ],
                Text(
                  t.portal.positions.usersCount(count: p.users),
                  style: muted,
                ),
              ],
            ),
          ),
          if (!p.isSystem) ...[
            AppBoxes.kWidth8,
            NeumorphicIconButton(
              icon: Icons.edit_outlined,
              tooltip: t.portal.positions.edit,
              busy: busy,
              onPressed: onEdit,
            ),
          ],
          if (p.canDelete) ...[
            AppBoxes.kWidth12,
            NeumorphicIconButton(
              icon: Icons.delete_outline,
              tooltip: t.portal.positions.delete,
              busy: busy,
              onPressed: onDelete,
            ),
          ],
        ],
      ),
    );
  }
}
