import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../../core/constants/app_insets.dart';
import '../../../../../core/error/failure.dart';
import '../../../../../core/gen/strings.g.dart';
import '../../../../../core/router/app_router.dart';
import '../../../../tasks/presentation/widgets/common/tasks_message.dart';
import '../../../../tasks/presentation/widgets/completed/day_separator.dart';
import '../../../domain/movement_history.dart';
import '../../bloc/movement_history_cubit.dart';
import 'move_record_tile.dart';

/// Лента «Завершённые» перемещения (ADHOC-28): перемещения всего склада по дням, свежие
/// сверху, подгрузка у конца ленты. Только со связью - офлайн лента не хранится. Вид - как
/// у «Завершённых» заданий: кладовщик листает обе ленты одинаково.
class MoveHistoryFeed extends StatefulWidget {
  const MoveHistoryFeed({super.key});

  @override
  State<MoveHistoryFeed> createState() => _MoveHistoryFeedState();
}

class _MoveHistoryFeedState extends State<MoveHistoryFeed> {
  /// Сколько не доезжая до конца ленты начинать подгрузку следующей страницы.
  static const _preloadExtent = 400.0;

  /// Подгрузить следующую страницу, когда лента подошла к концу.
  bool onScroll(ScrollNotification n) {
    if (n.metrics.extentAfter < _preloadExtent) {
      context.read<MovementHistoryCubit>().loadMore();
    }
    return false;
  }

  /// Открыть запись - что, откуда и куда перемещено.
  void openRecord(MoveRecord record) {
    context.router.push(MovementRecordRoute(movementId: record.id));
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<MovementHistoryCubit>().state;
    final cubit = context.read<MovementHistoryCubit>();

    switch (state.status) {
      case HistoryStatus.initial:
      case HistoryStatus.loading:
        return const Center(child: CircularProgressIndicator());
      case HistoryStatus.error:
        return TasksMessage(
          text: state.failure is NetworkFailure
              ? t.movement.historyOnlineOnly
              : t.movement.historyLoadFailed,
          showImage: true,
          onRetry: cubit.load,
        );
      case HistoryStatus.loaded:
        break;
    }
    if (state.items.isEmpty) {
      return RefreshIndicator(
        onRefresh: cubit.load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [TasksMessage(text: t.movement.historyEmpty)],
        ),
      );
    }

    final entries = groupHistoryByDay(state.items);
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
              HistoryDay(:final day) => DaySeparator(day: day),
              HistoryRecord(:final record) => MoveRecordTile(
                record: record,
                onTap: () => openRecord(record),
              ),
            };
          },
        ),
      ),
    );
  }
}
