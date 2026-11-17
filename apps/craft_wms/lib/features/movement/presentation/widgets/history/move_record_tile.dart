import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import '../../../../../core/constants/app_borders.dart';
import '../../../../../core/constants/app_boxes.dart';
import '../../../../../core/constants/app_colors.dart';
import '../../../../../core/constants/app_insets.dart';
import '../../../../../core/constants/app_sizes.dart';
import '../../../../../core/gen/strings.g.dart';
import '../../../../../core/theme/regular_text.dart';
import '../../../../../core/theme/semibold_text.dart';
import '../../../../../core/utils/date_time_format.dart';
import '../../../../../core/utils/doc_number.dart';
import '../../../domain/movement_history.dart';

/// Вид перемещения для человека; незнакомый - как есть.
String moveKindLabel(String kind) => switch (kind) {
  'move' => t.movement.kindMove,
  'replenish' => t.movement.kindReplenish,
  _ => kind,
};

/// Заголовок записи: вид и номер операции - «Перемещение ПМ-000001» (ADHOC-55).
String moveRecordTitle(MoveRecord record) {
  final docKind = operationDocKind(record.kind);
  if (docKind == null || record.number == 0) return moveKindLabel(record.kind);
  return t.movement.recordTitle(
    kind: moveKindLabel(record.kind),
    number: docNumber(docKind, record.number),
  );
}

/// Запись ленты «Завершённые» перемещения: вид, кто перемещал, сколько коробов и строк
/// товара, время. Вид - как у записи «Завершённых» заданий.
class MoveRecordTile extends StatelessWidget {
  const MoveRecordTile({super.key, required this.record, required this.onTap});

  final MoveRecord record;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final muted = RegularTextStyles().regularInter12.copyWith(
      color: AppColors.kTextMuted,
    );
    return Padding(
      padding: AppInsets.bottom8,
      child: NeumorphicButton(
        onPressed: onTap,
        padding: AppInsets.all12,
        style: NeumorphicStyle(
          shadowLightColor: AppColors.kNeumorphicLight,
          shadowDarkColor: AppColors.kNeumorphicDark,
          intensity: 1,
          color: AppColors.kNeumorphicBg,
          depth: 2,
          shape: NeumorphicShape.flat,
          boxShape: NeumorphicBoxShape.roundRect(AppBorders.kCircular8),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              MdiIcons.swapHorizontal,
              size: AppSizes.kIcon24,
              color: AppColors.kTileMovement,
            ),
            AppBoxes.kWidth12,
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    moveRecordTitle(record),
                    style: SemiboldTextStyles().semiboldInter14.copyWith(
                      color: AppColors.kSidebarHover,
                    ),
                  ),
                  Text(record.executor.fullName, style: muted),
                  Text(
                    t.movement.historySummary(
                      boxes: record.loadUnits,
                      goods: record.goods,
                    ),
                    style: muted,
                  ),
                ],
              ),
            ),
            AppBoxes.kWidth8,
            Text(timeOfDay(record.postedAtTime), style: muted),
          ],
        ),
      ),
    );
  }
}
