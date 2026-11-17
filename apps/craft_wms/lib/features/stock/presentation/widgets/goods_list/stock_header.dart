import 'package:flutter/material.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import '../../../../../core/constants/app_boxes.dart';
import '../../../../../core/constants/app_colors.dart';
import '../../../../../core/constants/app_insets.dart';
import '../../../../../core/constants/app_sizes.dart';
import '../../../../../core/gen/assets.gen.dart';
import '../../../../../core/widgets/appbar_image.dart';
import '../../../../../core/widgets/page_header.dart';
import '../../../../../core/widgets/pending_pass_badge.dart';

/// Шапка «Остатков» и «Номенклатуры» (ADHOC-33): картинка, заголовок (у «Остатков» - с переходом
/// во «Ввод остатков») и строка поиска открытой вкладки.
///
/// Вынесена из страницы, когда у «Остатков» появились вкладки (P5-05-1): вёрстка шапки
/// вытесняла из файла логику экрана. Строка поиска приходит готовой - у вкладок она своя.
class StockHeader extends StatelessWidget {
  const StockHeader({
    super.key,
    required this.title,
    required this.goBack,
    this.openStockEntry,
    required this.search,
  });

  final String title;
  final VoidCallback goBack;

  /// Открыть «Ввод остатков»; `null` - кнопки нет.
  final VoidCallback? openStockEntry;

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
                    PageHeader(title: title, goBack: goBack),
                    const Spacer(),
                    if (openStockEntry != null)
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
