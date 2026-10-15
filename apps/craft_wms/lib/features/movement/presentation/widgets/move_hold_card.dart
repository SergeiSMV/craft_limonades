import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';
import '../../../../core/widgets/neumorphic_action_button.dart';
import '../bloc/movement_state.dart';
import 'move_format.dart';

/// Карточка «что в руках» и что дальше (P6-04) — в том же стиле, что у размещения.
///
/// Источник (короб или россыпь ячейки): что сканировать дальше и «Выбрать товар» — для товара
/// без штрихкода. Взятый товар: куда положить и «Выбрать ячейку». Короб в руках можно и
/// поставить в ячейку из справочника — тем же «Выбрать ячейку». Взятый товар можно положить
/// в короб без скана — «Выбрать короб». Действия — стопкой неоморфных кнопок. Короб, выбранный вручную (ярлык испорчен), можно тут же
/// перепечатать — «Перепечатать ярлык».
class MoveHoldCard extends StatelessWidget {
  const MoveHoldCard({
    super.key,
    required this.hold,
    required this.onChooseGood,
    required this.onChooseCell,
    required this.onFindBox,
    required this.onReprint,
    required this.onDrop,
  });

  final MoveHold hold;
  final VoidCallback onChooseGood;
  final VoidCallback onChooseCell;
  final VoidCallback onFindBox;
  final VoidCallback onReprint;
  final VoidCallback onDrop;

  @override
  Widget build(BuildContext context) {
    final (title, from, hint) = switch (hold) {
      HoldSource(:final place) when place.isBox => (
        t.movement.sourceBox(
          code: boxCode(place.loadUnitId!),
          cell: place.cellAddress,
        ),
        null,
        t.movement.scanBoxHint,
      ),
      HoldSource(:final place) => (
        t.movement.sourceCell(cell: place.cellAddress),
        null,
        t.movement.scanCellHint,
      ),
      HoldGoods(
        :final good,
        :final productionDate,
        :final qty,
        :final from,
        :final internalWarehouseName,
      ) =>
        (
          goodsLabel(
            good,
            productionDate,
            qty,
            warehouse: internalWarehouseName,
          ),
          t.movement.from(place: placeLabel(from)),
          t.movement.scanTargetHint,
        ),
    };
    final source = hold is HoldSource ? hold as HoldSource : null;
    final isBox = source?.place.isBox ?? false;
    return Neumorphic(
      padding: AppInsets.all12,
      style: NeumorphicStyle(
        shadowLightColor: AppColors.kNeumorphicLight,
        shadowDarkColor: AppColors.kNeumorphicDark,
        intensity: 1,
        color: AppColors.kNeumorphicBg,
        depth: 3,
        boxShape: NeumorphicBoxShape.roundRect(AppBorders.kCircular8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            t.movement.inHands,
            style: RegularTextStyles().regularInter12.copyWith(
              color: AppColors.kTextMuted,
            ),
          ),
          Text(title, style: SemiboldTextStyles().semiboldInter14),
          if (from != null)
            Text(
              from,
              style: RegularTextStyles().regularInter12.copyWith(
                color: AppColors.kTextMuted,
              ),
            ),
          AppBoxes.kHeight8,
          Text(
            hint,
            style: SemiboldTextStyles().semiboldInter14.copyWith(
              color: AppColors.kTileTasks,
            ),
          ),
          AppBoxes.kHeight12,
          // Стопкой: на ширине ТСД в строку несколько действий не помещаются.
          NeumorphicActionStack(
            buttons: [
              if (hold is HoldSource)
                NeumorphicActionButton(
                  label: t.movement.chooseGood,
                  icon: MdiIcons.formatListBulleted,
                  onPressed: onChooseGood,
                ),
              if (hold is HoldGoods || isBox)
                NeumorphicActionButton(
                  label: t.movement.chooseCell,
                  icon: MdiIcons.viewGridOutline,
                  onPressed: onChooseCell,
                ),
              if (hold is HoldGoods)
                NeumorphicActionButton(
                  label: t.movement.findBox,
                  icon: MdiIcons.packageVariantClosed,
                  onPressed: onFindBox,
                ),
              if (isBox && source!.manual)
                NeumorphicActionButton(
                  label: t.movement.reprintLabel,
                  icon: MdiIcons.printer,
                  onPressed: onReprint,
                ),
              NeumorphicActionButton(
                label: t.movement.drop,
                icon: MdiIcons.undoVariant,
                onPressed: onDrop,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
