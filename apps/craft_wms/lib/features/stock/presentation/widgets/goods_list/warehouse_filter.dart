import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../../core/constants/app_insets.dart';
import '../../../../../core/constants/app_sizes.dart';
import '../../../../../core/constants/app_colors.dart';
import '../../../../../core/gen/strings.g.dart';
import '../../../../../core/theme/regular_text.dart';
import '../../../../../core/widgets/neumorphic_choice.dart';
import '../../bloc/goods_list_cubit.dart';

/// Фильтр «склады» в листе фильтров «Остатков» (ADHOC-33): внутренние склады с множественным
/// выбором, по умолчанию — все. Вкладок по складам нет: складов может быть много.
///
/// Склад «Основной» в соглашении терминала — `null`, поэтому вариант для него — `null`, а не id.
class WarehouseFilter extends StatelessWidget {
  const WarehouseFilter({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GoodsListCubit>().state;
    final cubit = context.read<GoodsListCubit>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: AppInsets.left6 + AppInsets.bottom8,
          child: Text(
            t.stockListScreen.filterWarehouses,
            style: RegularTextStyles().regularInter12.copyWith(
              color: AppColors.kTextMuted,
            ),
          ),
        ),
        Wrap(
          spacing: AppSizes.kChipSpacing,
          runSpacing: AppSizes.kChipSpacing,
          children: [
            NeumorphicChoice(
              label: t.stockListScreen.filterAll,
              selected: state.warehouseIds.isEmpty,
              onPressed: cubit.allWarehouses,
            ),
            for (final w in state.warehouses)
              NeumorphicChoice(
                label: w.name,
                selected: state.warehouseIds.contains(_key(w.id, w.isDefault)),
                onPressed: () => cubit.toggleWarehouse(_key(w.id, w.isDefault)),
              ),
          ],
        ),
      ],
    );
  }

  /// Склад в фильтре: «Основной» — `null`, остальные — id.
  static String? _key(String id, bool isDefault) => isDefault ? null : id;
}
