import 'package:craft_wms/core/theme/semibold_text.dart';
import 'package:flutter/material.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import '../../../../../core/constants/app_boxes.dart';
import '../../../../../core/constants/app_colors.dart';
import '../../../../../core/constants/app_insets.dart';
import '../../../../../core/constants/app_sizes.dart';
import '../../../../../core/gen/strings.g.dart';
import '../../../../../core/theme/bold_text.dart';
import '../../../../../core/theme/regular_text.dart';
import '../../../../../core/printer/load_unit_label.dart';
import '../../../../../core/utils/date_time_format.dart';
import '../../../../../core/utils/qty_format.dart';
import '../../../../../core/widgets/detail_card.dart';
import '../../../../contents/domain/stock_entities.dart';
import '../../../../contents/presentation/widgets/common/pending_mark.dart';

/// Строка остатка: булавка места хранения, адрес ячейки, короб (если товар в коробе), дата
/// партии и количество. Строк по одной ячейке может быть несколько — по одной на каждую партию
/// россыпью и в каждом коробе.
class PlaceTile extends StatelessWidget {
  const PlaceTile({super.key, required this.item});

  /// Место товара (ячейка · короб · партия · количество).
  final StockPlace item;

  @override
  Widget build(BuildContext context) {
    return DetailCard(
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.cellAddress ?? t.contents.unknownCell,
                  style: BoldTextStyles().boldInter16.copyWith(
                    color: AppColors.kSidebarHover,
                    height: 1.2,
                  ),
                ),
                if (item.loadUnitId case final box?)
                  Text(
                    t.contents.boxCode(
                      code: LoadUnitLabel(box).shortCodeFormatted,
                    ),
                    style: RegularTextStyles().regularInter12.copyWith(
                      color: AppColors.kTextMuted,
                    ),
                  ),
                Text(
                  t.stockDetailScreen.batch(
                    date: batchDate(item.productionDate),
                  ),
                  style: RegularTextStyles().regularInter12.copyWith(
                    color: AppColors.kTextMuted,
                  ),
                ),
                // Пометку показываем только у НЕосновного склада: подписывать каждую обычную
                // строку «Основной» — шум, а вот брак в общей ячейке должен бросаться в глаза.
                // Итог внизу экрана при этом суммирует всё: кладовщику нужно фактическое
                // количество на складе независимо от учётной принадлежности.
                if ((item.internalWarehouseName ?? '').isNotEmpty)
                  Container(
                    margin: AppInsets.top4,
                    padding: AppInsets.badge,
                    decoration: BoxDecoration(
                      color: AppColors.kBadgeWarningBg,
                      borderRadius: BorderRadius.circular(AppSizes.kText12),
                    ),
                    child: Text(
                      item.internalWarehouseName!,
                      style: RegularTextStyles().regularInter12.copyWith(
                        color: AppColors.kBadgeWarningText,
                      ),
                    ),
                  ),
                if (item.pending) const PendingMark(),
              ],
            ),
          ),
          AppBoxes.kWidth12,
          Padding(
            padding: AppInsets.right8,
            child: Text(
              fmtQty(item.qty),
              style: SemiboldTextStyles().semiboldInter18.copyWith(
                color: AppColors.kSidebarHover,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
