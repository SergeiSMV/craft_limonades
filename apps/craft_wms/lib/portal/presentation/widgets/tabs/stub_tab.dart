import 'package:flutter/material.dart';

import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/gen/strings.g.dart';

/// Заглушка вкладки портала: «раздел в разработке» + фаза, в которой он появится.
/// Зачем: каркас MVP показывает все 7 вкладок, но реально работает только Номенклатура -
/// остальные визуально присутствуют и честно помечены сроком (не пустой экран).
class StubTab extends StatelessWidget {
  const StubTab({super.key, required this.phase, required this.icon});

  /// Метка фазы, где раздел станет рабочим (напр. «P6», «P9», «P1-05»).
  final String phase;

  /// Иконка раздела (та же, что в боковом меню) - для узнаваемости.
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Card(
        child: Padding(
          padding: AppInsets.all60,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Иконка раздела на янтарной плашке (как stat-icon в макете).
              Container(
                width: AppSizes.kIcon56,
                height: AppSizes.kIcon56,
                decoration: const BoxDecoration(
                  color: AppColors.kPrimarySoft,
                  borderRadius: AppBorders.kCircular12,
                ),
                child: Icon(icon, size: AppSizes.kIcon28, color: AppColors.kPrimary),
              ),
              AppBoxes.kHeight24,
              Text(
                t.portal.stub.title,
                style: const TextStyle(fontSize: AppSizes.kText20, fontWeight: FontWeight.w600),
              ),
              AppBoxes.kHeight8,
              Container(
                padding: AppInsets.badge,
                decoration: const BoxDecoration(
                  color: AppColors.kBadgeInfoBg,
                  borderRadius: AppBorders.kPill,
                ),
                child: Text(
                  t.portal.stub.phase(phase: phase),
                  style: const TextStyle(
                    fontSize: AppSizes.kText12,
                    fontWeight: FontWeight.w600,
                    color: AppColors.kBadgeInfoText,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
