import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import '../../../../../core/constants/app_borders.dart';
import '../../../../../core/constants/app_boxes.dart';
import '../../../../../core/constants/app_colors.dart';
import '../../../../../core/constants/app_insets.dart';
import '../../../../../core/gen/strings.g.dart';
import '../../../../../core/theme/regular_text.dart';
import '../../../../../core/theme/semibold_text.dart';
import '../../bloc/goods_list_cubit.dart';

/// Виджет кнопка открытия листа фильтров с бейджем числа активных фильтров.
class FilterButton extends StatelessWidget {
  const FilterButton({super.key});

  /// Открыть нижний лист фильтров. Cubit пробрасываем через .value — лист им управляет.
  void openFilters(BuildContext context) {
    final cubit = context.read<GoodsListCubit>();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: false,
      builder: (_) =>
          BlocProvider.value(value: cubit, child: const _FilterSheet()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GoodsListCubit>().state;
    // Склад пока не учитываем (ADR-0016) — только группа + поставщик.
    final count =
        (state.groupId != null ? 1 : 0) + (state.supplierId != null ? 1 : 0);

    return Badge.count(
      count: count,
      isLabelVisible: count > 0,
      child: NeumorphicButton(
        onPressed: () => openFilters(context),
        style: NeumorphicStyle(
          shadowLightColor: AppColors.kNeumorphicLight,
          shadowDarkColor: AppColors.kNeumorphicDark,
          intensity: 1,
          color: AppColors.kNeumorphicBg,
          depth: -2,
          shape: NeumorphicShape.flat,
          boxShape: NeumorphicBoxShape.roundRect(AppBorders.kCircular8),
        ),
        padding: AppInsets.all12,
        child: Icon(MdiIcons.tune, color: AppColors.kTextMain),
      ),
    );
  }
}

/// Нижний лист фильтров: группа + поставщик (применяются сразу) + «Сбросить».
class _FilterSheet extends StatelessWidget {
  const _FilterSheet();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GoodsListCubit>().state;
    final cubit = context.read<GoodsListCubit>();

    return SafeArea(
      child: Padding(
        padding: AppInsets.all16,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              t.stockListScreen.filtersTitle,
              style: SemiboldTextStyles().semiboldInter18,
            ),
            AppBoxes.kHeight16,
            // key по значению — чтобы после «Сбросить» дропдаун показал «Все».
            DropdownButtonFormField<String?>(
              key: ValueKey('flt-group-${state.groupId}'),
              initialValue: state.groupId,
              isExpanded: true,
              borderRadius: AppBorders.kCircular8,
              decoration: InputDecoration(
                labelText: t.stockListScreen.filterGroup,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              items: [
                DropdownMenuItem<String?>(
                  value: null,
                  child: Text(t.stockListScreen.filterAll),
                ),
                for (final g in state.groups)
                  DropdownMenuItem<String?>(
                    value: g.id,
                    child: Text(
                      g.name,
                      overflow: TextOverflow.ellipsis,
                      style: RegularTextStyles().regularInter14,
                    ),
                  ),
              ],
              onChanged: cubit.setGroup,
            ),
            AppBoxes.kHeight12,
            DropdownButtonFormField<String?>(
              key: ValueKey('flt-supplier-${state.supplierId}'),
              initialValue: state.supplierId,
              isExpanded: true,
              borderRadius: AppBorders.kCircular8,
              decoration: InputDecoration(
                labelText: t.stockListScreen.filterSupplier,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              items: [
                DropdownMenuItem<String?>(
                  value: null,
                  child: Text(t.stockListScreen.filterAll),
                ),
                for (final s in state.suppliers)
                  DropdownMenuItem<String?>(
                    value: s.id,
                    child: Text(
                      s.name,
                      overflow: TextOverflow.ellipsis,
                      style: RegularTextStyles().regularInter14,
                    ),
                  ),
              ],
              onChanged: cubit.setSupplier,
            ),
            AppBoxes.kHeight16,
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: cubit.resetFilters,
                    child: Text(t.stockListScreen.reset),
                  ),
                ),
                AppBoxes.kWidth12,
                Expanded(
                  child: FilledButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(t.stockListScreen.done),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
