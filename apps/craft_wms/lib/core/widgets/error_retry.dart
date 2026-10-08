import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart';

import '../constants/app_borders.dart';
import '../constants/app_boxes.dart';
import '../constants/app_colors.dart';
import '../constants/app_sizes.dart';
import '../gen/assets.gen.dart';
import '../gen/strings.g.dart';

/// Блок ошибки с кнопкой «Повторить».
class ErrorRetry extends StatelessWidget {
  const ErrorRetry({super.key, required this.onRetry});

  /// Функция повторной попытки (например, повторный запрос к API).
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Assets.images.failedToLoad.image(
            width: AppSizes.kImagePlaceholder,
            height: AppSizes.kImagePlaceholder,
          ),
          Text(t.stockListScreen.error),
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
            child: Text(t.stockListScreen.retry),
          ),
        ],
      ),
    );
  }
}
