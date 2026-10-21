import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../../core/constants/app_insets.dart';
import '../../../../../core/error/failure.dart';
import '../../../../../core/gen/strings.g.dart';
import '../../../../../core/router/app_router.dart';
import '../../../../tasks/presentation/widgets/common/tasks_message.dart';
import '../../../../tasks/presentation/widgets/completed/day_separator.dart';
import '../../../domain/resolved_problems.dart';
import '../../bloc/resolved_problems_cubit.dart';
import 'resolved_tile.dart';

/// Лента «Завершённые» проблем склада (ADHOC-34): решённые офисом проблемы всего склада по
/// дням решения, свежие сверху, подгрузка у конца ленты. Только со связью — офлайн лента не
/// хранится. Вид — как у «Завершённых» заданий и перемещений.
class ResolvedFeed extends StatefulWidget {
  const ResolvedFeed({super.key});

  @override
  State<ResolvedFeed> createState() => _ResolvedFeedState();
}

class _ResolvedFeedState extends State<ResolvedFeed> {
  /// Сколько не доезжая до конца ленты начинать подгрузку следующей страницы.
  static const _preloadExtent = 400.0;

  /// Подгрузить следующую страницу, когда лента подошла к концу.
  bool onScroll(ScrollNotification n) {
    if (n.metrics.extentAfter < _preloadExtent) {
      context.read<ResolvedProblemsCubit>().loadMore();
    }
    return false;
  }

  /// Открыть карточку — проблема и решение офиса. Всё уже пришло в ленте, запроса нет.
  void openProblem(ResolvedProblem problem) {
    context.router.push(ResolvedProblemRoute(problem: problem));
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<ResolvedProblemsCubit>().state;
    final cubit = context.read<ResolvedProblemsCubit>();

    switch (state.status) {
      case ResolvedStatus.initial:
      case ResolvedStatus.loading:
        return const Center(child: CircularProgressIndicator());
      case ResolvedStatus.error:
        return TasksMessage(
          text: state.failure is NetworkFailure
              ? t.problems.resolvedOnlineOnly
              : t.problems.resolvedLoadFailed,
          showImage: true,
          onRetry: cubit.load,
        );
      case ResolvedStatus.loaded:
        break;
    }
    if (state.items.isEmpty) {
      return RefreshIndicator(
        onRefresh: cubit.load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [TasksMessage(text: t.problems.resolvedEmpty)],
        ),
      );
    }

    final entries = groupResolvedByDay(state.items);
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
              ResolvedDay(:final day) => DaySeparator(day: day),
              ResolvedRecord(:final problem) => ResolvedTile(
                problem: problem,
                onTap: () => openProblem(problem),
              ),
            };
          },
        ),
      ),
    );
  }
}
