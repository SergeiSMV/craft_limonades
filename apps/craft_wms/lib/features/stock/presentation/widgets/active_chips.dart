import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/theme/regular_text.dart';
import '../bloc/goods_list_cubit.dart';

/// Активные фильтры чипами (группа/поставщик). «✕» снимает фильтр сразу.
class ActiveChips extends StatelessWidget {
  const ActiveChips({super.key});

  /// Имя по id из справочника (пусто, если не нашли).
  String _nameOf(Iterable<String> names) => names.isEmpty ? '' : names.first;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GoodsListCubit>().state;
    final cubit = context.read<GoodsListCubit>();

    final chips = <Widget>[];
    if (state.groupId != null) {
      final name = _nameOf(
        state.groups.where((g) => g.id == state.groupId).map((g) => g.name),
      );
      chips.add(_chip(name, () => cubit.setGroup(null)));
    }
    if (state.supplierId != null) {
      final name = _nameOf(
        state.suppliers
            .where((s) => s.id == state.supplierId)
            .map((s) => s.name),
      );
      chips.add(_chip(name, () => cubit.setSupplier(null)));
    }
    if (chips.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: AppInsets.top16,
      child: Align(
        alignment: Alignment.centerLeft,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Wrap(spacing: 4, runSpacing: 8, children: chips),
        ),
      ),
    );
  }

  /// Чип активного фильтра: подпись + «✕», снимающий фильтр.
  Widget _chip(String label, VoidCallback onDeleted) => Chip(
    elevation: 2,
    shadowColor: AppColors.kStockItemBorder,
    side: BorderSide(color: AppColors.kStockItemBg),
    shape: RoundedRectangleBorder(borderRadius: AppBorders.kPill),
    backgroundColor: AppColors.kStockItemBg,
    label: Text(label, style: RegularTextStyles().regularInter12),
    onDeleted: onDeleted,
    deleteIcon: const Icon(Icons.close, size: AppSizes.kIcon16),
  );
}
