import 'package:flutter/material.dart';

import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';
import '../bloc/stock_entry_cubit.dart';

/// Плитка пройденной ячейки: адрес + число позиций; тап → редактировать, долгое нажатие → меню.
class CommittedCellTile extends StatelessWidget {
  const CommittedCellTile({
    super.key,
    required this.entry,
    required this.onTap,
    required this.onLongPress,
  });

  final CommittedCell entry;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

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
        leading: const Icon(Icons.inventory_2_outlined),
        title: Text(entry.cell.address, style: SemiboldTextStyles().semiboldInter16),
        subtitle: Text(
          t.stockEntry.cellPositions(count: entry.lines.length),
          style: RegularTextStyles().regularInter12.copyWith(color: AppColors.kTextMuted),
        ),
        trailing: const Icon(Icons.chevron_right, color: AppColors.kTextMuted),
        onTap: onTap,
        onLongPress: onLongPress,
      ),
    );
  }
}
