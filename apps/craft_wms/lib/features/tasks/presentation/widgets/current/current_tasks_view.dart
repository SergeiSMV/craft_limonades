import '../../../../../core/auth/session_rights.dart';
import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../../core/constants/app_colors.dart';
import '../../../../../core/constants/app_insets.dart';
import '../../../../../core/error/failure.dart';
import '../../../../../core/gen/strings.g.dart';
import '../../../../../core/router/app_router.dart';
import '../../../../../core/theme/regular_text.dart';
import '../../../data/tasks_models.dart';
import '../../bloc/current_tasks_cubit.dart';
import '../common/task_format.dart';
import '../common/tasks_message.dart';
import 'task_tile.dart';

/// Вкладка «Текущие»: пул и свои взятые задания. Без связи - снимок с пометкой времени.
class CurrentTasksView extends StatelessWidget {
  const CurrentTasksView({super.key});

  /// Открыть карточку задания; по возврату список обновляется - задание могли взять,
  /// отдать или выполнить.
  ///
  /// Пересчёт (P10-04) открывается сразу списком ячеек: карточки с позициями у него нет -
  /// работники берут из него ячейки.
  Future<void> openTask(BuildContext context, WarehouseTask task) async {
    final cubit = context.read<CurrentTasksCubit>();
    final stocktakeId = task.stocktakeId;
    await context.router.push(
      task.kind == TaskKind.stocktake && stocktakeId != null
          ? StocktakeRoute(
              stocktakeId: stocktakeId,
              number: task.stocktake?.number,
            )
          : TaskDetailRoute(taskId: task.id, task: task),
    );
    await cubit.load();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<CurrentTasksCubit>().state;
    final cubit = context.read<CurrentTasksCubit>();

    switch (state.status) {
      case CurrentTasksStatus.initial:
      case CurrentTasksStatus.loading:
        return const Center(child: CircularProgressIndicator());
      case CurrentTasksStatus.error:
        return TasksMessage(
          text: state.failure is NetworkFailure
              ? t.tasks.noConnection
              : t.tasks.loadFailed,
          showImage: true,
          onRetry: cubit.load,
        );
      case CurrentTasksStatus.loaded:
        break;
    }

    // Только виды заданий, на которые у должности есть право (ADHOC-51).
    final tasks = [
      for (final task in state.visible)
        if (_allowed(context, task.kind)) task,
    ];
    return RefreshIndicator(
      onRefresh: cubit.load,
      child: ListView(
        padding: AppInsets.h8,
        // Пустой список тоже тянется вниз - иначе обновить его было бы нечем.
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          if (state.fromCache && state.syncedAt != null)
            Padding(
              padding: AppInsets.bottom8,
              child: Text(
                t.tasks.offlineSnapshot(time: shortDateTime(state.syncedAt!)),
                style: RegularTextStyles().regularInter12.copyWith(
                  color: AppColors.kBadgeWarningText,
                ),
              ),
            ),
          if (tasks.isEmpty)
            TasksMessage(text: t.tasks.emptyCurrent)
          else
            for (final task in tasks)
              TaskTile(task: task, onTap: () => openTask(context, task)),
        ],
      ),
    );
  }

  bool _allowed(BuildContext context, String kind) {
    final rights = taskKindRights(kind);
    return sessionCan(
      context,
      rights.first,
      more: rights.skip(1).toList(),
      withoutSession: true,
    );
  }
}
