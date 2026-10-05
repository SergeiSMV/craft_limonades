import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';
import '../bloc/receipt_cubit.dart';

/// Шапка рабочего экрана приёмки: от кого принимаем, куда кладём и в какой короб.
///
/// Все три вещи видны постоянно: они определяют, куда ляжет следующий скан, и кладовщик
/// должен видеть это до скана, а не узнавать из списка строк после.
class ReceiptContextBar extends StatelessWidget {
  const ReceiptContextBar({
    super.key,
    required this.state,
    required this.onChangeCell,
    required this.onNewBox,
    required this.onPickBox,
    required this.onBoxMenu,
  });

  final ReceiptState state;

  /// Сменить ячейку для новых строк и коробов.
  final VoidCallback onChangeCell;

  /// Завести новый короб и напечатать ярлык.
  final VoidCallback onNewBox;

  /// Выбрать один из коробов приёмки (ярлык не читается).
  final VoidCallback onPickBox;

  /// Действия с текущим коробом: допечатать ярлык, закрыть.
  final VoidCallback onBoxMenu;

  @override
  Widget build(BuildContext context) {
    final supplier = state.supplier;
    final cell = state.targetCell;
    final cellText = cell == null
        ? t.receipt.cellDefault(address: state.defaultCell?.address ?? '')
        : t.receipt.cell(address: cell.address);
    return Container(
      color: AppColors.kNeumorphicBg,
      padding: AppInsets.all8,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: AppInsets.left6,
            child: Text(
              supplier == null
                  ? t.receipt.supplierNone
                  : t.receipt.supplier(name: supplier.name),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: RegularTextStyles().regularInter12.copyWith(
                color: AppColors.kTextMuted,
              ),
            ),
          ),
          AppBoxes.kHeight8,
          _BarButton(
            onPressed: onChangeCell,
            text: cellText,
            icon: MdiIcons.cogTransfer,
          ),
          AppBoxes.kHeight8,
          Row(
            children: [
              Expanded(child: _boxButton()),
              if (state.boxes.isNotEmpty) ...[
                AppBoxes.kWidth8,
                _IconBarButton(
                  onPressed: onPickBox,
                  icon: MdiIcons.formatListBulleted,
                ),
              ],
              AppBoxes.kWidth8,
              _IconBarButton(
                onPressed: onNewBox,
                icon: MdiIcons.packageVariantPlus,
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Текущий короб с его наполнением либо «Штучно».
  Widget _boxButton() {
    final box = state.currentBox;
    if (box == null) {
      return _BarButton(
        onPressed: onNewBox,
        text: t.receipt.loose,
        icon: MdiIcons.packageVariant,
      );
    }
    return _BarButton(
      onPressed: onBoxMenu,
      text:
          '${t.receipt.box(code: box.shortCode)} · ${t.receipt.boxPositions(count: state.linesInBox(box.id))}',
      icon: MdiIcons.packageVariantClosed,
      highlighted: true,
    );
  }
}

/// Выпуклая кнопка-строка шапки — как шапка ячейки во «Вводе остатков».
class _BarButton extends StatelessWidget {
  const _BarButton({
    required this.onPressed,
    required this.text,
    required this.icon,
    this.highlighted = false,
  });

  final VoidCallback onPressed;
  final String text;
  final IconData icon;

  /// Короб в работе выделен цветом: в него ляжет следующая строка.
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final color = highlighted ? AppColors.kPrimary : AppColors.kSidebarHover;
    return NeumorphicButton(
      onPressed: onPressed,
      style: NeumorphicStyle(
        shadowLightColor: AppColors.kNeumorphicLight,
        shadowDarkColor: AppColors.kNeumorphicDark,
        intensity: 1,
        color: AppColors.kNeumorphicBg,
        depth: 3,
        shape: NeumorphicShape.flat,
        boxShape: NeumorphicBoxShape.roundRect(AppBorders.kCircular8),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: SemiboldTextStyles().semiboldInter14.copyWith(
                color: color,
              ),
            ),
          ),
          AppBoxes.kWidth8,
          Icon(icon, size: AppSizes.kIcon25, color: color),
        ],
      ),
    );
  }
}

/// Квадратная выпуклая кнопка-иконка — как кнопка отмены во «Вводе остатков».
class _IconBarButton extends StatelessWidget {
  const _IconBarButton({required this.onPressed, required this.icon});

  final VoidCallback onPressed;
  final IconData icon;

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
        boxShape: NeumorphicBoxShape.roundRect(AppBorders.kCircular8),
      ),
      padding: AppInsets.all12,
      child: Icon(icon, color: AppColors.kSidebarHover, size: AppSizes.kIcon20),
    );
  }
}
