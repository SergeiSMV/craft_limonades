import 'package:flutter/material.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import '../../../../../core/constants/app_boxes.dart';
import '../../../../../core/constants/app_colors.dart';
import '../../../../../core/constants/app_insets.dart';
import '../../../../../core/constants/app_sizes.dart';
import '../../../../../core/gen/strings.g.dart';
import '../../../../../core/printer/load_unit_label.dart';
import '../../../../../core/theme/bold_text.dart';
import '../../../../../core/theme/regular_text.dart';
import '../../../../../core/utils/date_time_format.dart';
import '../../../../../core/widgets/detail_card.dart';
import '../../../../../core/widgets/section_title.dart';
import '../../../domain/contents_entities.dart';
import '../common/contents_message.dart';
import '../common/freshness_note.dart';
import '../common/good_line_tile.dart';
import '../common/pending_mark.dart';
import 'reprint_button.dart';

/// Карточка короба: короткий код, где лежит, что внутри (P5-05); перепечатка ярлыка
/// и история (P5-05-1); товар в коробе ведёт в свою карточку. Тянется вниз — перечитать.
class LoadUnitBody extends StatelessWidget {
  const LoadUnitBody({
    super.key,
    required this.data,
    required this.onRefresh,
    required this.reprintBusy,
    required this.onReprint,
    required this.onOpenGood,
    required this.history,
  });

  final Viewed<LoadUnitView> data;
  final Future<void> Function() onRefresh;

  /// Идёт печать ярлыка.
  final bool reprintBusy;
  final VoidCallback onReprint;

  /// Открыть карточку товара из строки содержимого.
  final void Function(ContentLine line) onOpenGood;

  /// Блок истории — со своим состоянием, поэтому приходит готовым виджетом.
  final Widget history;

  @override
  Widget build(BuildContext context) {
    final lu = data.value;
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView(
        padding: AppInsets.h8 + AppInsets.bottom8,
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          if (lu == null)
            ContentsMessage(text: _notFound())
          else ...[
            _header(lu),
            AppBoxes.kHeight8,
            ReprintButton(busy: reprintBusy, onPressed: onReprint),
            AppBoxes.kHeight8,
            FreshnessNote(freshness: data.freshness),
            SectionTitle(title: t.contents.linesTitle),
            if (lu.lines.isEmpty) ContentsMessage(text: t.contents.boxEmpty),
            // Вертикальный отступ 8 у каждой плашки и боковой 8 у списка дают то же, что в
            // «Товарах»: 8 от края экрана и 16 между плашками, тень не режется.
            for (final line in lu.lines)
              Padding(
                padding: AppInsets.v8,
                child: GoodLineTile(line: line, onTap: () => onOpenGood(line)),
              ),
            history,
          ],
        ],
      ),
    );
  }

  /// «Не найден»: без связи — с оговоркой, что короб мог появиться после загрузки снимка.
  String _notFound() => switch (data.freshness) {
    FromSnapshot(asOf: final asOf?) => t.contents.notFoundSnapshot(
      time: shortDateTime(asOf),
    ),
    _ => t.contents.notFound,
  };

  /// Шапка: код с ярлыка, ячейка, пометки.
  Widget _header(LoadUnitView lu) => DetailCard(
    padding: AppInsets.all12,
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          MdiIcons.packageVariantClosed,
          size: AppSizes.kIcon28,
          color: AppColors.kPlacePin,
        ),
        AppBoxes.kWidth12,
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                t.contents.boxCode(
                  code: LoadUnitLabel(lu.id).shortCodeFormatted,
                ),
                style: BoldTextStyles().boldInter20.copyWith(
                  color: AppColors.kSidebarHover,
                ),
              ),
              AppBoxes.kHeight4,
              Row(
                children: [
                  Icon(
                    MdiIcons.mapMarker,
                    size: AppSizes.kIcon18,
                    color: AppColors.kDanger,
                  ),
                  AppBoxes.kWidth4,
                  Text(
                    lu.cellAddress ?? t.contents.notPlaced,
                    style: BoldTextStyles().boldInter16.copyWith(
                      color: AppColors.kSidebarHover,
                    ),
                  ),
                ],
              ),
              if (!lu.live)
                Padding(
                  padding: AppInsets.top4,
                  child: Text(
                    t.contents.notLive,
                    style: RegularTextStyles().regularInter12.copyWith(
                      color: AppColors.kDanger,
                    ),
                  ),
                ),
              if (lu.pending) const PendingMark(),
            ],
          ),
        ),
      ],
    ),
  );
}
