import 'package:flutter/material.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';

/// Страница-список портала (ADHOC-56, страница-индекс Shopify Polaris): панель поиска и фильтров
/// закреплена сверху, прокручивается только список под ней.
///
/// Как: ширина - по центру, не шире [AppSizes.kPortalListMaxWidth]; панель и список растянуты
/// на эту ширину и выровнены по одним краям. Уже [AppSizes.kPortalCompactWidth] - поля меньше.
/// [header] - над панелью, тоже закреплён: переключатель видов страницы («Инвентаризация»).
class PortalListPage extends StatelessWidget {
  const PortalListPage({
    super.key,
    required this.toolbar,
    required this.body,
    this.header,
  });

  final Widget toolbar;
  final Widget body;
  final Widget? header;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final narrow = constraints.maxWidth < AppSizes.kPortalCompactWidth;
      final padding = narrow ? AppInsets.pageCompact : AppInsets.page;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: padding.copyWith(bottom: 0),
            child: _Width(
              child: Padding(
                padding: AppInsets.bottom16,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (header != null) ...[header!, AppBoxes.kHeight16],
                    toolbar,
                  ],
                ),
              ),
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: padding.copyWith(top: 0),
              child: _Width(child: body),
            ),
          ),
        ],
      );
    },
  );
}

/// По центру, не шире [AppSizes.kPortalListMaxWidth], содержимое - на всю эту ширину: панель
/// начинается от левого края таблицы, а не центрируется по своей ширине.
class _Width extends StatelessWidget {
  const _Width({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: AppSizes.kPortalListMaxWidth),
      child: SizedBox(width: double.infinity, child: child),
    ),
  );
}
