import 'package:flutter/material.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/widgets/neumorphic_action_button.dart';

/// Ручной выбор источника, когда в руках пусто (P6-04): ярлык короба испорчен или этикетка
/// ячейки затёрлась. Скан остаётся основным путём — он подтверждает, что кладовщик держит
/// именно это; ручной выбор — запасной.
class MoveManualPick extends StatelessWidget {
  const MoveManualPick({
    super.key,
    required this.onChooseCell,
    required this.onFindBox,
  });

  final VoidCallback onChooseCell;
  final VoidCallback onFindBox;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          t.movement.noLabelHint,
          style: RegularTextStyles().regularInter12.copyWith(
            color: AppColors.kTextMuted,
          ),
        ),
        AppBoxes.kHeight8,
        NeumorphicActionStack(
          buttons: [
            NeumorphicActionButton(
              label: t.movement.chooseCell,
              icon: MdiIcons.viewGridOutline,
              onPressed: onChooseCell,
            ),
            NeumorphicActionButton(
              label: t.movement.findBox,
              icon: MdiIcons.packageVariantClosed,
              onPressed: onFindBox,
            ),
          ],
        ),
      ],
    );
  }
}
