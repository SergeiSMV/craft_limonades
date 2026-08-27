import 'package:flutter/material.dart';

import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';
import '../../../../core/utils/qty_format.dart';
import '../bloc/stock_entry_cubit.dart';

/// Строка буфера: товар · партия · количество (с единицей). ШК на строке не хранится — привязки
/// живут отдельно (уровень товара), поэтому и метки ШК на строке нет.
class LineTile extends StatelessWidget {
  const LineTile({super.key, required this.line, this.onLongPress});

  final EntryLineDraft line;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: AppInsets.bottom4,
      decoration: BoxDecoration(
        borderRadius: AppBorders.kCircular8,
        color: AppColors.kStockItemBg,
        border: Border(bottom: BorderSide(color: AppColors.kStockItemBorder)),
      ),
      child: ListTile(
        onLongPress: onLongPress,
        title: Text(
          line.good.name,
          style: RegularTextStyles().regularInter12.copyWith(
            color: AppColors.kSidebarHover,
          ),
        ),
        subtitle: Text(
          t.stockEntry.lineSubtitle(date: line.productionDate),
          style: RegularTextStyles().regularInter10.copyWith(
            color: AppColors.kTextMuted,
          ),
        ),
        trailing: Text(
          t.stockEntry.qtyWithUom(qty: fmtQty(line.qty), uom: line.good.uom),
          style: SemiboldTextStyles().semiboldInter14,
        ),
      ),
    );
  }
}
