import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import '../../../../../core/constants/app_colors.dart';
import '../../../../../core/constants/app_sizes.dart';
import '../../../../tasks/presentation/widgets/common/tasks_filter_sheet.dart';
import '../../bloc/movement_history_cubit.dart';

/// Кнопка фильтра ленты «Завершённые» перемещения в шапке раздела, с бейджем числа условий.
/// Лист — общий с заданиями, без вида: период и исполнитель.
class MoveHistoryFilterButton extends StatelessWidget {
  const MoveHistoryFilterButton({super.key});

  /// Открыть фильтр и применить выбранное — лента перезагружается отдельным запросом.
  Future<void> openFilter(BuildContext context) async {
    final cubit = context.read<MovementHistoryCubit>();
    if (cubit.state.executors.isEmpty) await cubit.loadExecutors();
    if (!context.mounted) return;
    final picked = await showTasksFilterSheet(
      context,
      current: cubit.state.filter,
      executors: cubit.state.executors,
      showKind: false,
    );
    if (picked != null) await cubit.setFilter(picked);
  }

  @override
  Widget build(BuildContext context) {
    final count = context.select(
      (MovementHistoryCubit c) => c.state.filter.activeCount,
    );
    return IconButton(
      onPressed: () => openFilter(context),
      icon: Badge.count(
        count: count,
        isLabelVisible: count > 0,
        child: Icon(
          MdiIcons.filterVariant,
          size: AppSizes.kIcon25,
          color: AppColors.kNeumorphicBg,
        ),
      ),
    );
  }
}
