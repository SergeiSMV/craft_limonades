import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import '../../../../../core/constants/app_colors.dart';
import '../../../../../core/constants/app_sizes.dart';
import '../../../data/tasks_models.dart';
import '../../bloc/completed_tasks_cubit.dart';
import '../../bloc/current_tasks_cubit.dart';
import 'tasks_filter_sheet.dart';

/// Кнопка фильтра в шапке раздела «ЗАДАНИЯ» с бейджем числа заданных условий.
///
/// Фильтр - у выбранной вкладки: «Текущие» пока фильтруются только по виду задания,
/// «Завершённые» - по периоду, исполнителю и виду.
class TasksFilterButton extends StatelessWidget {
  const TasksFilterButton({super.key, required this.completedTab});

  /// Выбрана вкладка «Завершённые».
  final bool completedTab;

  /// Открыть фильтр выбранной вкладки и применить выбранное.
  Future<void> openFilter(BuildContext context) async {
    if (!completedTab) {
      final cubit = context.read<CurrentTasksCubit>();
      final picked = await showTasksFilterSheet(
        context,
        current: CompletedFilter(kind: cubit.state.kind),
        kindOnly: true,
      );
      if (picked != null) cubit.setKind(picked.kind);
      return;
    }
    final cubit = context.read<CompletedTasksCubit>();
    if (cubit.state.executors.isEmpty) await cubit.loadExecutors();
    if (!context.mounted) return;
    final picked = await showTasksFilterSheet(
      context,
      current: cubit.state.filter,
      executors: cubit.state.executors,
    );
    if (picked != null) await cubit.setFilter(picked);
  }

  @override
  Widget build(BuildContext context) {
    final count = completedTab
        ? context.select((CompletedTasksCubit c) => c.state.filter.activeCount)
        : context.select((CurrentTasksCubit c) => c.state.kind == null ? 0 : 1);
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
