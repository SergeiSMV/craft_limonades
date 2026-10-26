import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';

/// Что сделать с насчитанным.
enum LineMenuAction { edit, remove }

/// Меню насчитанного — тот же лист, что у строки «Ввода остатков»: исправить и убрать.
Future<LineMenuAction?> showLineMenuSheet(
  BuildContext context, {
  required bool canEdit,
  required String removeLabel,
}) => showModalBottomSheet<LineMenuAction>(
  backgroundColor: AppColors.kNeumorphicBg,
  context: context,
  builder: (ctx) => SafeArea(
    child: Padding(
      padding: AppInsets.all16,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (canEdit) ...[
            _MenuButton(
              icon: Icons.edit_outlined,
              label: t.stocktake.lineEdit,
              onPressed: () => Navigator.of(ctx).pop(LineMenuAction.edit),
            ),
            AppBoxes.kHeight8,
          ],
          _MenuButton(
            icon: Icons.delete_outline,
            label: removeLabel,
            danger: true,
            onPressed: () => Navigator.of(ctx).pop(LineMenuAction.remove),
          ),
        ],
      ),
    ),
  ),
);

class _MenuButton extends StatelessWidget {
  const _MenuButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.danger = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    return NeumorphicButton(
      onPressed: onPressed,
      style: NeumorphicStyle(
        shadowLightColor: AppColors.kNeumorphicLight,
        shadowDarkColor: AppColors.kNeumorphicDark,
        intensity: 1,
        color: AppColors.kNeumorphicBg,
        depth: 3,
        shape: NeumorphicShape.flat,
      ),
      child: ListTile(
        leading: Icon(icon, color: danger ? AppColors.kDanger : null),
        title: Text(
          label,
          style: danger
              ? RegularTextStyles().regularInter14.copyWith(
                  color: AppColors.kDanger,
                )
              : null,
        ),
      ),
    );
  }
}
