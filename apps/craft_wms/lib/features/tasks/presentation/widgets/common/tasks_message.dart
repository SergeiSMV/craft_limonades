import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart';

import '../../../../../core/constants/app_borders.dart';
import '../../../../../core/constants/app_boxes.dart';
import '../../../../../core/constants/app_colors.dart';
import '../../../../../core/constants/app_insets.dart';
import '../../../../../core/constants/app_sizes.dart';
import '../../../../../core/gen/assets.gen.dart';
import '../../../../../core/gen/strings.g.dart';
import '../../../../../core/theme/regular_text.dart';

/// Сообщение вместо списка: пусто, нет связи, ошибка. С кнопкой «Повторить», если есть что
/// повторять.
class TasksMessage extends StatelessWidget {
  const TasksMessage({
    super.key,
    required this.text,
    this.onRetry,
    this.showImage = false,
  });

  final String text;
  final VoidCallback? onRetry;
  final bool showImage;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: AppInsets.all24,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showImage)
              Assets.images.failedToLoad.image(
                width: AppSizes.kImagePlaceholder,
                height: AppSizes.kImagePlaceholder,
              ),
            Text(
              text,
              textAlign: TextAlign.center,
              style: RegularTextStyles().regularInter14.copyWith(
                color: AppColors.kTextMuted,
              ),
            ),
            if (onRetry != null) ...[
              AppBoxes.kHeight24,
              NeumorphicButton(
                onPressed: onRetry,
                style: NeumorphicStyle(
                  shadowLightColor: AppColors.kNeumorphicLight,
                  shadowDarkColor: AppColors.kNeumorphicDark,
                  intensity: 1,
                  color: AppColors.kNeumorphicBg,
                  depth: 3,
                  shape: NeumorphicShape.flat,
                  boxShape: NeumorphicBoxShape.roundRect(AppBorders.kPill),
                ),
                child: Text(t.tasks.retry),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
