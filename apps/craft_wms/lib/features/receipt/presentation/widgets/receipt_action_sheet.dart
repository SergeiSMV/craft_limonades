import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';

/// Пункт нижнего меню действий.
class ReceiptAction<T> {
  const ReceiptAction({
    required this.value,
    required this.icon,
    required this.label,
    this.danger = false,
  });

  final T value;
  final IconData icon;
  final String label;

  /// Необратимое действие — красным, как удаление в «Вводе остатков».
  final bool danger;
}

/// Нижнее меню действий в принятом стиле (выпуклые неоморф-кнопки, как меню строки во
/// «Вводе остатков»). Возвращает значение выбранного пункта или `null`.
Future<T?> showReceiptActionSheet<T>(
  BuildContext context,
  List<ReceiptAction<T>> actions,
) => showModalBottomSheet<T>(
  backgroundColor: AppColors.kNeumorphicBg,
  context: context,
  builder: (sheetContext) => SafeArea(
    child: Padding(
      padding: AppInsets.all16,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < actions.length; i++) ...[
            if (i > 0) AppBoxes.kHeight8,
            _ActionButton(
              action: actions[i],
              onPressed: () => Navigator.of(sheetContext).pop(actions[i].value),
            ),
          ],
        ],
      ),
    ),
  ),
);

class _ActionButton<T> extends StatelessWidget {
  const _ActionButton({required this.action, required this.onPressed});

  final ReceiptAction<T> action;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final color = action.danger ? AppColors.kDanger : null;
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
        leading: Icon(action.icon, color: color),
        title: Text(action.label, style: TextStyle(color: color)),
      ),
    );
  }
}
