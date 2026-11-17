import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../../core/constants/app_insets.dart';
import '../../../../../core/error/failure.dart';
import '../../../../../core/gen/strings.g.dart';
import '../../../../../core/router/app_router.dart';
import '../../../domain/tasks_models.dart';
import '../../bloc/completed_tasks_cubit.dart';
import '../common/tasks_message.dart';
import 'completed_tile.dart';
import 'day_separator.dart';

/// Лента «Завершённые»: записи по дням, как в чате, свежие сверху; подгрузка у конца ленты.
/// Только со связью - офлайн лента не хранится (решение 2026-10-07).
class CompletedFeed extends StatefulWidget {
  const CompletedFeed({super.key});

  @override
  State<CompletedFeed> createState() => _CompletedFeedState();
}

class _CompletedFeedState extends State<CompletedFeed> {
  /// Сколько не доезжая до конца ленты начинать подгрузку следующей страницы.
  static const _preloadExtent = 400.0;

  /// Подгрузить следующую страницу, когда лента подошла к концу.
  bool onScroll(ScrollNotification n) {
    if (n.metrics.extentAfter < _preloadExtent) {
      context.read<CompletedTasksCubit>().loadMore();
    }
    return false;
  }

  /// Открыть карточку выполненного задания - посмотреть заходы.
  void openTask(CompletedTask task) {
    context.router.push(TaskDetailRoute(taskId: task.id));
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<CompletedTasksCubit>().state;
    final cubit = context.read<CompletedTasksCubit>();

    switch (state.status) {
      case CompletedStatus.initial:
      case CompletedStatus.loading:
        return const Center(child: CircularProgressIndicator());
      case CompletedStatus.error:
        return TasksMessage(
          text: state.failure is NetworkFailure
              ? t.tasks.completedOnlineOnly
              : t.tasks.loadFailed,
          showImage: true,
          onRetry: cubit.load,
        );
      case CompletedStatus.loaded:
        break;
    }
    if (state.items.isEmpty) {
      return RefreshIndicator(
        onRefresh: cubit.load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [TasksMessage(text: t.tasks.emptyCompleted)],
        ),
      );
    }

    final entries = groupByDay(state.items);
    return NotificationListener<ScrollNotification>(
      onNotification: onScroll,
      child: RefreshIndicator(
        onRefresh: cubit.load,
        child: ListView.builder(
          padding: AppInsets.h8,
          physics: const AlwaysScrollableScrollPhysics(),
          itemCount: entries.length + (state.loadingMore ? 1 : 0),
          itemBuilder: (context, i) {
            if (i == entries.length) {
              return const Padding(
                padding: AppInsets.all16,
                child: Center(child: CircularProgressIndicator()),
              );
            }
            return switch (entries[i]) {
              FeedDay(:final day) => DaySeparator(day: day),
              FeedTask(:final task) => CompletedTile(
                task: task,
                onTap: () => openTask(task),
              ),
            };
          },
        ),
      ),
    );
  }
}
