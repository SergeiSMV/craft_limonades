import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/gen/assets.gen.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';

/// Поле скана приёмки: ввод только сканером, тап - ручной выбор товара.
///
/// Тот же приём, что в «Вводе остатков»: аппаратная «клавиатура» DT50 печатает код в поле,
/// софт-клавиатура не показывается, чтобы не всплывать после каждого скана.
class ReceiptScanField extends StatelessWidget {
  const ReceiptScanField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onTap,
    required this.onSubmitted,
  });

  final TextEditingController controller;
  final FocusNode focusNode;

  /// Ручной выбор товара (товар без штрихкода).
  final VoidCallback onTap;

  /// Код, пришедший в поле от сканера.
  final ValueChanged<String> onSubmitted;

  @override
  Widget build(BuildContext context) {
    return Neumorphic(
      style: NeumorphicStyle(
        shadowLightColor: AppColors.kNeumorphicLight,
        shadowDarkColor: AppColors.kNeumorphicDark,
        intensity: 1,
        color: AppColors.kNeumorphicBg,
        depth: 3,
        shape: NeumorphicShape.flat,
        boxShape: NeumorphicBoxShape.roundRect(AppBorders.kCircular8),
      ),
      child: TextField(
        onTap: onTap,
        showCursor: false,
        controller: controller,
        focusNode: focusNode,
        autofocus: true,
        keyboardType: TextInputType.none,
        textInputAction: TextInputAction.done,
        onSubmitted: onSubmitted,
        decoration: InputDecoration(
          filled: true,
          fillColor: AppColors.kNeumorphicBg,
          suffixIcon: Padding(
            padding: AppInsets.right10,
            child: Icon(
              MdiIcons.viewList,
              color: AppColors.kSidebarHover,
              size: AppSizes.kIcon25,
            ),
          ),
          hintText: t.receipt.scanGood,
          hintStyle: RegularTextStyles().regularInter14.copyWith(
            color: AppColors.kSidebarHover,
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

/// Пустая приёмка - подсказка, что делать.
///
/// По центру, когда места хватает, и с прокруткой, когда нет (ADHOC-18): неподвижная колонка
/// с картинкой переполнялась на DT50S, стоило экрану сжаться под клавиатурой.
class ReceiptEmptyHint extends StatelessWidget {
  const ReceiptEmptyHint({super.key});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Center(child: _content()),
        ),
      ),
    );
  }

  Widget _content() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Assets.icons.stockEntryEmpty.image(
          width: AppSizes.kIcon140,
          height: AppSizes.kIcon140,
        ),
        Text(
          t.receipt.empty,
          style: RegularTextStyles().regularInter14.copyWith(
            color: AppColors.kTextMuted,
          ),
        ),
      ],
    );
  }
}
