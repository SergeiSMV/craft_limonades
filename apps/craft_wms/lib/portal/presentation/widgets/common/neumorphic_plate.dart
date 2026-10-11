import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart';

import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';

/// Выпуклая неоморфная плашка портала (ADHOC-25/26): карточка пользователя в сайдбаре,
/// панель поиска и фильтров, таблица документов.
class NeumorphicPlate extends StatelessWidget {
  const NeumorphicPlate({
    super.key,
    required this.child,
    this.padding = AppInsets.all16,
  });

  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Neumorphic(
      padding: padding,
      style: NeumorphicStyle(
        color: AppColors.kBg,
        shadowLightColor: AppColors.kNeumorphicLight,
        shadowDarkColor: AppColors.kNeumorphicDark,
        intensity: 1,
        depth: AppSizes.kNeumorphicDepth,
        shape: NeumorphicShape.flat,
        boxShape: NeumorphicBoxShape.roundRect(AppBorders.kCircular16),
      ),
      child: child,
    );
  }
}
