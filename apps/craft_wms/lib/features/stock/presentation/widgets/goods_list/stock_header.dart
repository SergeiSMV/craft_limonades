import 'package:flutter/material.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import '../../../../../core/constants/app_boxes.dart';
import '../../../../../core/constants/app_colors.dart';
import '../../../../../core/constants/app_insets.dart';
import '../../../../../core/constants/app_sizes.dart';
import '../../../../../core/gen/assets.gen.dart';
import '../../../../../core/gen/strings.g.dart';
import '../../../../../core/widgets/appbar_image.dart';
import '../../../../../core/widgets/page_header.dart';
import '../../../../../core/widgets/pending_pass_badge.dart';

/// Шапка «Остатков»: картинка, заголовок с переходом во «Ввод остатков» и строка поиска
/// открытой вкладки.
///
/// Вынесена из страницы, когда у «Остатков» появились вкладки (P5-05-1): вёрстка шапки
/// вытесняла из файла логику экрана. Строка поиска приходит готовой — у вкладок она своя.
class StockHeader extends StatelessWidget {
  const StockHeader({
    super.key,
    required this.goBack,
    required this.openStockEntry,
    required this.search,
  });

  final VoidCallback goBack;

  /// Открыть «Ввод остатков».
  final VoidCallback openStockEntry;

  /// Строка поиска открытой вкладки.
  final Widget search;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        AppbarImage(image: Assets.images.featuredSnacks),
        Padding(
          padding: AppInsets.h8 + AppInsets.top32,
          child: Column(
            children: [
              Padding(
                padding: AppInsets.right8,
                child: Row(
                  children: [
                    PageHeader(title: t.stockListScreen.title, goBack: goBack),
                    const Spacer(),
                    PendingPassBadge(
                      child: InkWell(
                        onTap: openStockEntry,
                        child: Icon(
                          MdiIcons.playlistPlus,
                          size: AppSizes.kIcon30,
                          color: AppColors.kNeumorphicBg,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              AppBoxes.kHeight16,
              search,
            ],
          ),
        ),
      ],
    );
  }
}
