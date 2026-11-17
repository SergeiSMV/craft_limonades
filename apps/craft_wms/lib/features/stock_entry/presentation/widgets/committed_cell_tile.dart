import 'package:craft_wms/core/constants/app_insets.dart';
import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';
import '../../domain/entry_models.dart';

/// Плитка пройденной ячейки: адрес + число позиций; тап → редактировать, долгое нажатие → меню.
class CommittedCellTile extends StatelessWidget {
  const CommittedCellTile({
    super.key,
    required this.entry,
    required this.onTap,
    required this.onLongPress,
  });

  /// Пройденная ячейка со строками буфера.
  final CommittedCell entry;

  /// Тап по плитке - открыть ячейку на редактирование.
  final VoidCallback onTap;

  /// Долгое нажатие - меню (редактировать/удалить).
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: AppInsets.top8,
      child: Neumorphic(
        style: NeumorphicStyle(
          shadowLightColor: AppColors.kNeumorphicLight,
          shadowDarkColor: AppColors.kNeumorphicDark,
          intensity: 1,
          color: AppColors.kNeumorphicBg,
          depth: 3,
          shape: NeumorphicShape.flat,
        ),
        child: Padding(
          padding: AppInsets.all8 + AppInsets.h8,
          child: InkWell(
            onTap: onTap,
            onLongPress: onLongPress,
            child: Row(
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.cell.address,
                      style: SemiboldTextStyles().semiboldInter16,
                    ),
                    Text(
                      t.stockEntry.cellPositions(count: entry.lines.length),
                      style: RegularTextStyles().regularInter12.copyWith(
                        color: AppColors.kTextMuted,
                      ),
                    ),
                  ],
                ),
                const Spacer(),
                const Icon(Icons.chevron_right, color: AppColors.kTextMuted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
