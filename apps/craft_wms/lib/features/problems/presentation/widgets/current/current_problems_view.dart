import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../../core/constants/app_colors.dart';
import '../../../../../core/constants/app_insets.dart';
import '../../../../../core/error/failure.dart';
import '../../../../../core/gen/strings.g.dart';
import '../../../../../core/router/app_router.dart';
import '../../../../../core/theme/regular_text.dart';
import '../../../../tasks/presentation/widgets/common/tasks_message.dart';
import '../../../../tasks/presentation/widgets/completed/day_separator.dart';
import '../../../domain/problem_records.dart';
import '../../bloc/current_problems_cubit.dart';
import '../records/record_days.dart';
import '../records/record_tile.dart';

/// Вкладка «Текущие» в «Проблемах склада» (ADHOC-35): открытые проблемы всего склада по дням
/// фиксации, свои неотправленные - сверху; внизу «Добавить» - к фиксации новой проблемы.
///
/// Список склада - только со связью; без неё видны свои неотправленные и подсказка: свои -
/// из очереди терминала, и кладовщик видит, что зафиксированное без сети не пропало.
class CurrentProblemsView extends StatelessWidget {
  const CurrentProblemsView({super.key, this.onAdd});

  /// Перейти к фиксации новой проблемы.
  /// «Пометить товар»; `null` - у должности нет права помечать (ADHOC-51), кнопки нет.
  final VoidCallback? onAdd;

  /// Открыть карточку - всё уже пришло в списке, запроса нет.
  void openProblem(BuildContext context, ProblemRecord problem) =>
      context.router.push(ProblemRecordRoute(problem: problem));

  @override
  Widget build(BuildContext context) {
    final state = context.watch<CurrentProblemsCubit>().state;
    final cubit = context.read<CurrentProblemsCubit>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: _list(context, state, cubit)),
        if (onAdd != null)
          Padding(
            padding: AppInsets.all16,
            child: FilledButton(onPressed: onAdd, child: Text(t.problems.add)),
          ),
      ],
    );
  }

  Widget _list(
    BuildContext context,
    CurrentProblemsState state,
    CurrentProblemsCubit cubit,
  ) {
    if (state.status != CurrentStatus.loaded) {
      return const Center(child: CircularProgressIndicator());
    }
    final failure = state.data.failure;
    final items = state.items;
    if (items.isEmpty) {
      return RefreshIndicator(
        onRefresh: cubit.load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            TasksMessage(
              text: switch (failure) {
                null => t.problems.currentEmpty,
                NetworkFailure() => t.problems.currentOnlineOnly,
                _ => t.problems.currentLoadFailed,
              },
              showImage: failure != null,
              onRetry: failure != null ? cubit.load : null,
            ),
          ],
        ),
      );
    }
    final entries = groupRecordsByDay(items);
    return RefreshIndicator(
      onRefresh: cubit.load,
      child: ListView.builder(
        padding: AppInsets.h8,
        physics: const AlwaysScrollableScrollPhysics(),
        // Первым - подсказка, если список склада не получен: видны только свои.
        itemCount: entries.length + (failure != null ? 1 : 0),
        itemBuilder: (context, i) {
          if (failure != null) {
            if (i == 0) return _note(failure);
            i -= 1;
          }
          return switch (entries[i]) {
            RecordDay(:final day) => DaySeparator(day: day),
            RecordItem(:final problem) => ProblemRecordTile(
              problem: problem,
              onTap: () => openProblem(context, problem),
            ),
          };
        },
      ),
    );
  }

  /// Почему над своими нет открытых склада.
  Widget _note(Failure failure) => Padding(
    padding: AppInsets.v8 + AppInsets.left6,
    child: Text(
      failure is NetworkFailure
          ? t.problems.currentOnlineOnly
          : t.problems.currentLoadFailed,
      style: RegularTextStyles().regularInter12.copyWith(
        color: AppColors.kBadgeWarningText,
      ),
    ),
  );
}
