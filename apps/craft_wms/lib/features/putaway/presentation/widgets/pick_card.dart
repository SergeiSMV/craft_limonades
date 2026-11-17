import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart';

import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';
import '../bloc/putaway_models.dart';
import 'putaway_format.dart';

/// Карточка «что в руках»: что взято и что дальше - скан ячейки или выбор её вручную,
/// «Положить обратно». Когда в руках ничего нет, карточки нет вовсе: подсказку «отсканируйте
/// короб или товар» уже показывает поле скана, и вторая такая же выглядела вторым полём.
class PickCard extends StatelessWidget {
  const PickCard({
    super.key,
    required this.pick,
    required this.onChooseCell,
    required this.onDrop,
  });

  final PutawayPick pick;
  final VoidCallback onChooseCell;
  final VoidCallback onDrop;

  @override
  Widget build(BuildContext context) {
    final p = pick;
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
            t.putaway.inHands,
            style: RegularTextStyles().regularInter12.copyWith(
              color: AppColors.kTextMuted,
            ),
          ),
          Text(pickTitle(p), style: SemiboldTextStyles().semiboldInter14),
          AppBoxes.kHeight8,
          Text(
            t.putaway.scanCellHint,
            style: SemiboldTextStyles().semiboldInter14.copyWith(
              color: AppColors.kTileTasks,
            ),
          ),
          Row(
            children: [
              TextButton(
                onPressed: onChooseCell,
                child: Text(t.putaway.chooseCell),
              ),
              const Spacer(),
              TextButton(onPressed: onDrop, child: Text(t.putaway.dropPick)),
            ],
          ),
        ],
      ),
    );
  }
}
