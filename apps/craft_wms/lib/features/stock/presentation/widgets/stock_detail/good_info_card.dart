import 'package:flutter/material.dart';

import '../../../../../core/constants/app_boxes.dart';
import '../../../../../core/constants/app_colors.dart';
import '../../../../../core/constants/app_insets.dart';
import '../../../../../core/gen/strings.g.dart';
import '../../../../../core/theme/regular_text.dart';
import '../../../../../core/theme/semibold_text.dart';
import '../../../data/catalog_models.dart';
import 'expandable_card.dart';

/// Шапка карточки товара: наименование видно всегда, реквизиты (код, единица, группа,
/// поставщик) раскрываются тапом по шапке.
///
/// Зачем сворачивать: на экране ТСД важнее остатки по ячейкам — реквизиты нужны редко,
/// а в свёрнутом виде список мест хранения виден без прокрутки.
class GoodInfoCard extends StatelessWidget {
  const GoodInfoCard({super.key, required this.good});

  /// Товар, чьи остатки открыты.
  final Good good;

  @override
  Widget build(BuildContext context) {
    return ExpandableCard(
      headerBuilder: (expanded) => Text(
        good.name,
        // В свёрнутом виде длинное наименование из 1С обрезаем, чтобы оно не раздувало
        // шапку; в раскрытом — показываем целиком.
        maxLines: expanded ? null : _collapsedNameLines,
        overflow: expanded ? TextOverflow.clip : TextOverflow.ellipsis,
        style: SemiboldTextStyles().semiboldInter14.copyWith(
          color: AppColors.kTextMain,
          height: 1.2,
        ),
      ),
      child: _Props(good: good),
    );
  }

  /// Предел строк наименования в свёрнутом виде.
  static const int _collapsedNameLines = 3;
}

/// Раскрывающийся блок реквизитов товара: код, единица, группа, поставщик.
class _Props extends StatelessWidget {
  const _Props({required this.good});

  /// Товар, чьи реквизиты выводим.
  final Good good;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: AppInsets.h16 + AppInsets.bottom16,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Divider(height: 1, color: AppColors.kBorder),
          AppBoxes.kHeight12,
          if (good.supplierName != null)
            _InlineProp(
              label: t.stockDetailScreen.labelSupplier,
              value: good.supplierName!,
            ),
          if (good.groupName != null)
            _InlineProp(
              label: t.stockDetailScreen.labelGroup,
              value: good.groupName!,
            ),
          _InlineProp(label: t.stockDetailScreen.labelUom, value: good.uom),
          if (good.code != null)
            _InlineProp(
              label: t.stockDetailScreen.labelCode,
              value: good.code!,
            ),
        ],
      ),
    );
  }
}

/// Реквизит одной строкой: серая подпись + значение жирным.
class _InlineProp extends StatelessWidget {
  const _InlineProp({required this.label, required this.value});

  /// Подпись реквизита («Код:»).
  final String label;

  /// Значение реквизита.
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: AppInsets.bottom4,
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '$label ',
              style: RegularTextStyles().regularInter12.copyWith(
                color: AppColors.kSidebarHover,
              ),
            ),
            TextSpan(
              text: value,
              style: RegularTextStyles().regularInter12.copyWith(
                color: AppColors.kSidebarHover,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
