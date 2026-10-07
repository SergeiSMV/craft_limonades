import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart';

import '../../../../../core/constants/app_borders.dart';
import '../../../../../core/constants/app_colors.dart';
import '../../../../../core/constants/app_insets.dart';
import '../../../../../core/gen/strings.g.dart';
import '../../../../../core/theme/semibold_text.dart';

/// Переключатель вкладок раздела: «Текущие» / «Завершённые». Неоморфный тумблер — тот же
/// приём «вдавленное поле, выпуклая выбранная кнопка», что у полей и кнопок приложения.
class TasksTabSwitch extends StatelessWidget {
  const TasksTabSwitch({
    super.key,
    required this.selected,
    required this.onSelected,
  });

  final int selected;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final style = SemiboldTextStyles().semiboldInter14;
    return NeumorphicToggle(
      selectedIndex: selected,
      onChanged: onSelected,
      padding: AppInsets.all2,
      style: NeumorphicToggleStyle(
        backgroundColor: AppColors.kNeumorphicBg,
        borderRadius: AppBorders.kCircular8,
        depth: -2,
      ),
      thumb: Neumorphic(
        style: NeumorphicStyle(
          color: AppColors.kNeumorphicBg,
          shadowLightColor: AppColors.kNeumorphicLight,
          shadowDarkColor: AppColors.kNeumorphicDark,
          boxShape: NeumorphicBoxShape.roundRect(AppBorders.kCircular8),
        ),
      ),
      children: [
        ToggleElement(
          background: Center(child: Text(t.tasks.tabCurrent, style: style)),
          foreground: Center(
            child: Text(
              t.tasks.tabCurrent,
              style: style.copyWith(color: AppColors.kTileTasks),
            ),
          ),
        ),
        ToggleElement(
          background: Center(child: Text(t.tasks.tabCompleted, style: style)),
          foreground: Center(
            child: Text(
              t.tasks.tabCompleted,
              style: style.copyWith(color: AppColors.kTileTasks),
            ),
          ),
        ),
      ],
    );
  }
}
