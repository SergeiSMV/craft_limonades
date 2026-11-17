import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart';

import '../constants/app_borders.dart';
import '../constants/app_colors.dart';
import '../constants/app_insets.dart';
import '../constants/app_sizes.dart';
import '../theme/regular_text.dart';

/// Строка поиска: неоморфная плашка, иконка поиска слева, крестик очистки справа.
///
/// Вынесена из страницы отдельным виджетом: вёрстка поля занимала треть файла и мешала читать
/// логику экрана. Состояние поля живёт в странице - контроллер нужен ей самой, чтобы показывать
/// в строке текст пришедшего интентом скана (ADHOC-06). В `core` - с P5-05-1: тем же полем
/// в «Остатках» ищут и товары, и короба по короткому коду.
class SearchField extends StatelessWidget {
  const SearchField({
    super.key,
    required this.hintText,
    required this.controller,
    required this.onChanged,
    required this.onSubmitted,
    required this.onClear,
  });

  /// Подсказка в пустом поле - что здесь ищут.
  final String hintText;

  /// Контроллер строки: по нему показывается крестик и чистится поле.
  final TextEditingController controller;

  /// Ввод изменился - поиск с дебаунсом.
  final ValueChanged<String> onChanged;

  /// Ввод завершён (Enter сканера или «Поиск» на клавиатуре).
  final ValueChanged<String> onSubmitted;

  /// Тап по крестику: очистить поле и сбросить запрос.
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return Neumorphic(
      style: NeumorphicStyle(
        shadowLightColor: AppColors.kNeumorphicLight,
        shadowDarkColor: AppColors.kNeumorphicDark,
        intensity: 1,
        color: AppColors.kNeumorphicBg,
        depth: -2,
        shape: NeumorphicShape.flat,
      ),
      child: TextField(
        controller: controller,
        cursorColor: AppColors.kTextMain,
        cursorWidth: 1.5,
        cursorHeight: 20,
        onChanged: onChanged,
        onSubmitted: onSubmitted,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          prefixIcon: Padding(
            padding: AppInsets.right2 + AppInsets.left12,
            child: Icon(
              Icons.search,
              size: AppSizes.kIcon25,
              color: AppColors.kTextMuted,
            ),
          ),
          prefixIconConstraints: const BoxConstraints(
            minWidth: 0,
            minHeight: 0,
          ),
          // Крестик очистки - только когда в поле что-то есть. Слушаем контроллер, чтобы
          // перерисовывался один суффикс, а не весь экран на каждый символ.
          suffixIcon: ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (context, value, _) => value.text.isEmpty
                ? const SizedBox.shrink()
                : GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onClear,
                    child: Padding(
                      padding: AppInsets.h14,
                      child: Icon(
                        Icons.close,
                        size: AppSizes.kIcon20,
                        color: AppColors.kTextMuted,
                      ),
                    ),
                  ),
          ),
          suffixIconConstraints: const BoxConstraints(
            minWidth: 0,
            minHeight: 0,
          ),
          hintText: hintText,
          hintStyle: RegularTextStyles().regularInter16.copyWith(
            color: AppColors.kBorderDashed,
          ),
          border: const OutlineInputBorder(
            borderRadius: AppBorders.kCircular8,
            borderSide: BorderSide.none,
          ),
          isDense: true,
        ),
      ),
    );
  }
}
