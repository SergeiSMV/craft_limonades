import 'package:flutter/material.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import '../../../../../core/constants/app_boxes.dart';
import '../../../../../core/constants/app_colors.dart';
import '../../../../../core/constants/app_insets.dart';
import '../../../../../core/constants/app_sizes.dart';
import '../../../../../core/gen/strings.g.dart';
import '../../../../../core/theme/bold_text.dart';
import '../../../../../core/widgets/detail_card.dart';
import '../../../../../core/widgets/section_title.dart';
import '../../../domain/contents_entities.dart';
import '../common/box_list_tile.dart';
import '../common/contents_message.dart';
import '../common/freshness_note.dart';
import '../common/good_line_tile.dart';

/// Содержимое ячейки: адрес, короба и россыпь (P5-05). Короба и россыпь — неоморфными
/// плашками в стиле списка товаров (P5-05-1). Тянется вниз — перечитать.
class CellContentsBody extends StatelessWidget {
  const CellContentsBody({
    super.key,
    required this.data,
    required this.onRefresh,
    required this.onOpenLoadUnit,
    required this.onOpenGood,
  });

  final Viewed<CellView> data;
  final Future<void> Function() onRefresh;
  final void Function(LoadUnitView loadUnit) onOpenLoadUnit;

  /// Открыть карточку товара из строки россыпи.
  final void Function(ContentLine line) onOpenGood;

  @override
  Widget build(BuildContext context) {
    final cell = data.value!;
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView(
        // Отступы — у элементов: неоморфные плашки, как в списке товаров, держат свои 8 со всех
        // сторон, чтобы тень не резалась краем.
        padding: AppInsets.bottom8,
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          Padding(
            padding: AppInsets.h8,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _header(cell),
                AppBoxes.kHeight8,
                FreshnessNote(freshness: data.freshness),
                if (cell.isEmpty) ContentsMessage(text: t.contents.cellEmpty),
                if (cell.loadUnits.isNotEmpty)
                  SectionTitle(
                    title: t.contents.boxesTitle(count: cell.loadUnits.length),
                  ),
              ],
            ),
          ),
          for (final lu in cell.loadUnits)
            Padding(
              padding: AppInsets.all8,
              child: BoxListTile(
                loadUnit: lu,
                showCell: false,
                onTap: () => onOpenLoadUnit(lu),
              ),
            ),
          if (cell.loose.isNotEmpty)
            Padding(
              padding: AppInsets.h8,
              child: SectionTitle(title: t.contents.looseTitle),
            ),
          for (final line in cell.loose)
            Padding(
              padding: AppInsets.all8,
              child: GoodLineTile(line: line, onTap: () => onOpenGood(line)),
            ),
        ],
      ),
    );
  }

  /// Шапка: булавка и адрес ячейки.
  Widget _header(CellView cell) => DetailCard(
    padding: AppInsets.all12,
    child: Row(
      children: [
        Icon(
          MdiIcons.mapMarker,
          size: AppSizes.kIcon28,
          color: AppColors.kDanger,
        ),
        AppBoxes.kWidth12,
        Expanded(
          child: Text(
            cell.address,
            style: BoldTextStyles().boldInter20.copyWith(
              color: AppColors.kSidebarHover,
            ),
          ),
        ),
      ],
    ),
  );
}
