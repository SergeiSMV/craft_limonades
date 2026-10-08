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
import '../common/content_line_tile.dart';
import '../common/contents_message.dart';
import '../common/freshness_note.dart';
import 'load_unit_tile.dart';

/// Содержимое ячейки: адрес, короба и россыпь (P5-05). Тянется вниз — перечитать.
class CellContentsBody extends StatelessWidget {
  const CellContentsBody({
    super.key,
    required this.data,
    required this.onRefresh,
    required this.onOpenLoadUnit,
  });

  final Viewed<CellView> data;
  final Future<void> Function() onRefresh;
  final void Function(LoadUnitView loadUnit) onOpenLoadUnit;

  @override
  Widget build(BuildContext context) {
    final cell = data.value!;
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView(
        padding: AppInsets.h8 + AppInsets.bottom8,
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          _header(cell),
          AppBoxes.kHeight8,
          FreshnessNote(freshness: data.freshness),
          if (cell.isEmpty) ContentsMessage(text: t.contents.cellEmpty),
          if (cell.loadUnits.isNotEmpty) ...[
            SectionTitle(
              title: t.contents.boxesTitle(count: cell.loadUnits.length),
            ),
            for (final lu in cell.loadUnits)
              Padding(
                padding: AppInsets.bottom8,
                child: LoadUnitTile(
                  loadUnit: lu,
                  onTap: () => onOpenLoadUnit(lu),
                ),
              ),
          ],
          if (cell.loose.isNotEmpty) ...[
            SectionTitle(title: t.contents.looseTitle),
            for (final line in cell.loose)
              Padding(
                padding: AppInsets.bottom8,
                child: ContentLineTile(line: line),
              ),
          ],
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
