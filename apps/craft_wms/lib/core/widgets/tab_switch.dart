import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart';

import '../constants/app_borders.dart';
import '../constants/app_colors.dart';
import '../constants/app_insets.dart';
import '../theme/semibold_text.dart';

/// Переключатель вкладок раздела: «Текущие / Завершённые» в «Заданиях», «Товары / Короба»
/// в «Остатках» (P5-05-1). Неоморфный тумблер - тот же приём «вдавленное поле, выпуклая
/// выбранная кнопка», что у полей и кнопок приложения.
///
/// Вынесен из «Заданий» в `core`: второй раздел с вкладками должен выглядеть так же, а копия
/// разошлась бы с первым при первой же правке.
class TabSwitch extends StatelessWidget {
  const TabSwitch({
    super.key,
    required this.labels,
    required this.selected,
    required this.onSelected,
    required this.activeColor,
  });

  /// Подписи вкладок по порядку.
  final List<String> labels;
  final int selected;
  final ValueChanged<int> onSelected;

  /// Цвет подписи выбранной вкладки - цвет плитки раздела в главном меню.
  final Color activeColor;

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
        for (final label in labels)
          ToggleElement(
            background: Center(child: Text(label, style: style)),
            foreground: Center(
              child: Text(label, style: style.copyWith(color: activeColor)),
            ),
          ),
      ],
    );
  }
}
