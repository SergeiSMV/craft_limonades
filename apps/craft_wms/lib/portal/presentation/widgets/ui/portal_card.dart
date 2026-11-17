import 'package:flutter/material.dart';

import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_colors.dart';

/// Карточка портала в плоском стиле (ADHOC-56, по Shopify Polaris).
///
/// Что: белая поверхность с тонкой рамкой и едва заметной нижней тенью - основа раздела.
/// Как: [children] идут строками через разделитель - список справочника; строка сама задаёт
///      свои отступы. Скругление обрезает содержимое, чтобы подсветка строки не вылезала за край.
class PortalCard extends StatelessWidget {
  const PortalCard({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: AppColors.kCardBg,
        borderRadius: AppBorders.kCircular12,
        border: Border.fromBorderSide(BorderSide(color: AppColors.kBorder)),
        boxShadow: [
          BoxShadow(
            color: AppColors.kCardShadow,
            offset: Offset(0, 1),
            blurRadius: 2,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: AppBorders.kCircular12,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0)
                const Divider(
                  height: 1,
                  thickness: 1,
                  color: AppColors.kDivider,
                ),
              children[i],
            ],
          ],
        ),
      ),
    );
  }
}
