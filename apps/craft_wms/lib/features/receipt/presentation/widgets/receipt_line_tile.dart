import 'package:flutter/material.dart';

import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';
import '../../../../core/utils/qty_format.dart';
import '../bloc/receipt_models.dart';

/// Строка приёмки: товар · партия · ячейка · количество.
///
/// Ячейка показывается у штучных строк: в общем списке они могут лежать в разных ячейках,
/// и без пометки кладовщик не отличил бы две строки одного товара. На странице короба ячейка
/// одна на весь короб и стоит в шапке — там её на строке нет.
class ReceiptLineTile extends StatelessWidget {
  const ReceiptLineTile({
    super.key,
    required this.line,
    this.cellAddress,
    this.onLongPress,
  });

  final ReceiptLineDraft line;

  /// Адрес ячейки строки; `null` — не показывать (строка короба).
  final String? cellAddress;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final batch = t.receipt.lineSubtitle(date: line.productionDate);
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
          cellAddress == null ? batch : '$batch · $cellAddress',
          style: RegularTextStyles().regularInter10.copyWith(
            color: AppColors.kTextMuted,
          ),
        ),
        trailing: Text(
          t.receipt.qtyWithUom(qty: fmtQty(line.qty), uom: line.good.uom),
          style: SemiboldTextStyles().semiboldInter14,
        ),
      ),
    );
  }
}
