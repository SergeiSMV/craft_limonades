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

/// Строка пользователя (ADHOC-50): ФИО, должность, вход — каждый факт своей строкой; изменить,
/// выдать новый бейдж или пароль, заблокировать. Себя заблокировать нельзя — кнопки нет.
class UserRow extends StatelessWidget {
  const UserRow({
    super.key,
    required this.user,
    required this.self,
    required this.busy,
    required this.onEdit,
    required this.onNewSecret,
    required this.onToggle,
  });

  final PortalUser user;

  /// Это вошедший оператор.
  final bool self;
  final bool busy;
  final VoidCallback onEdit;
  final VoidCallback onNewSecret;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final u = user;
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
                      u.fullName,
                      style: SemiboldTextStyles().semiboldInter14.copyWith(
                        color: u.isActive
                            ? AppColors.kTextMain
                            : AppColors.kTextMuted,
                      ),
                    ),
                    if (!u.isActive)
                      AccessMark(
                        label: t.portal.users.markBlocked,
                        bg: AppColors.kBadgeWarningBg,
                        fg: AppColors.kBadgeWarningText,
                      ),
                  ],
                ),
                AppBoxes.kHeight4,
                Text(
                  t.portal.users.position(name: u.positionName),
                  style: muted,
                ),
                Text(
                  u.byBadge
                      ? t.portal.users.badge(login: u.login)
                      : t.portal.users.username(login: u.username),
                  style: muted,
                ),
              ],
            ),
          ),
          AppBoxes.kWidth8,
          NeumorphicIconButton(
            icon: Icons.edit_outlined,
            tooltip: t.portal.users.edit,
            busy: busy,
            onPressed: onEdit,
          ),
          AppBoxes.kWidth12,
          NeumorphicIconButton(
            icon: u.byBadge ? Icons.badge_outlined : Icons.key_outlined,
            tooltip: u.byBadge
                ? t.portal.users.newBadge
                : t.portal.users.newPassword,
            busy: busy,
            onPressed: onNewSecret,
          ),
          if (!self) ...[
            AppBoxes.kWidth12,
            NeumorphicIconButton(
              icon: u.isActive ? Icons.block : Icons.lock_open_outlined,
              tooltip: u.isActive
                  ? t.portal.users.block
                  : t.portal.users.unblock,
              busy: busy,
              onPressed: onToggle,
            ),
          ],
        ],
      ),
    );
  }
}
