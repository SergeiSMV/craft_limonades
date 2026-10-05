import 'package:flutter/material.dart';

import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';
import '../../../../core/utils/qty_format.dart';
import '../bloc/receipt_models.dart';

/// Строка приёмки: товар · партия · где лежит (короб или штучно, ячейка) · количество.
///
/// Место показано на каждой строке: строки разных коробов и ячеек идут в одном списке,
/// и без пометки кладовщик не отличил бы две строки одного товара.
class ReceiptLineTile extends StatelessWidget {
  const ReceiptLineTile({
    super.key,
    required this.line,
    required this.boxCode,
    required this.cellAddress,
    this.onLongPress,
  });

  final ReceiptLineDraft line;

  /// Короткий код короба строки; `null` — штучно.
  final String? boxCode;

  /// Адрес ячейки строки (для ячейки по умолчанию — её адрес).
  final String cellAddress;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final place = boxCode == null
        ? t.receipt.lineLoose
        : t.receipt.lineBox(code: boxCode!);
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
          '${t.receipt.lineSubtitle(date: line.productionDate)} · $place · $cellAddress',
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
