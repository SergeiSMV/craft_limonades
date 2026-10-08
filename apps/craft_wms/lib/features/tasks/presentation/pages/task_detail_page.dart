import 'package:auto_route/auto_route.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter/material.dart';

import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/error/failure.dart';
import '../../../../core/error/failure_reason.dart';
import '../../../../core/gen/assets.gen.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/router/app_router.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';
import '../../../../core/widgets/page_header.dart';
import '../../../../core/widgets/system_ui_wrapper.dart';
import '../../data/tasks_models.dart';
import '../bloc/task_detail_cubit.dart';
import '../widgets/common/task_format.dart';
import '../widgets/common/task_status_badge.dart';
import '../widgets/common/tasks_message.dart';
import '../widgets/detail/history_tile.dart';
import '../widgets/detail/task_actions_bar.dart';
import '../widgets/detail/task_item_tile.dart';

/// Карточка задания (P5-02-1): что разместить, заходы, «Взять» / «Отказаться».
///
/// Из «Текущих» задание передаётся целиком и открывается без связи; из ленты «Завершённые» —
/// только [taskId], и задание дочитывается с сервера.
@RoutePage()
class TaskDetailPage extends StatelessWidget {
  const TaskDetailPage({super.key, required this.taskId, this.task});

  final String taskId;
  final WarehouseTask? task;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) =>
          getIt<TaskDetailCubit>(param1: taskId, param2: task)..refresh(),
      child: const _TaskDetailView(),
    );
  }
}

class _TaskDetailView extends StatelessWidget {
  const _TaskDetailView();

  /// Вернуться к списку.
  void goBack(BuildContext context) => context.router.maybePop();

  /// Подтвердить отказ: задание уйдёт в общий список, и его может взять другой.
  Future<void> confirmRelease(BuildContext context) async {
    final cubit = context.read<TaskDetailCubit>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.tasks.releaseConfirmTitle),
        content: Text(t.tasks.releaseConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(t.tasks.releaseConfirmNo),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(t.tasks.releaseConfirmYes),
          ),
        ],
      ),
    );
    if (ok == true) await cubit.release();
  }

  /// Начать размещение по заданию (P5-03); по возврату карточка обновляется — задание могло
  /// быть выполнено или вернуться в пул.
  Future<void> execute(BuildContext context) async {
    final cubit = context.read<TaskDetailCubit>();
    final task = cubit.state.task;
    if (task == null) return;
    await context.router.push(PutawayRoute(task: task));
    await cubit.refresh();
  }

  /// Показать итог «Взять» / «Отказаться» и забыть его.
  void onAction(BuildContext context, TaskDetailState state) {
    final action = state.lastAction;
    if (action == null) return;
    final text = switch (action) {
      TaskTaken() => t.tasks.taken,
      TaskReleased() => t.tasks.released,
      TaskActionFailed(:final failure) =>
        failure is NetworkFailure
            ? t.tasks.actionNeedsConnection
            : t.tasks.actionFailed(reason: failureReason(failure)),
    };
    snack(context, text);
    context.read<TaskDetailCubit>().clearAction();
    // Отдал задание — делать в карточке больше нечего.
    if (action is TaskReleased) goBack(context);
  }

  void snack(BuildContext context, String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<TaskDetailCubit>();
    return BlocConsumer<TaskDetailCubit, TaskDetailState>(
      listenWhen: (a, b) =>
          b.lastAction != null && a.lastAction != b.lastAction,
      listener: onAction,
      builder: (context, state) {
        final task = state.task;
        return SystemUiWrapper(
          style: StatusBarStyle.light,
          child: Scaffold(
            backgroundColor: AppColors.kNeumorphicBg,
            // Шапка — как у раздела «ЗАДАНИЯ» и «Приёмки»: фон-картинка и заголовок с возвратом.
            appBar: AppBar(
              automaticallyImplyLeading: false,
              backgroundColor: Colors.transparent,
              elevation: 0,
              toolbarHeight: AppSizes.kIcon60,
              flexibleSpace: ClipRRect(
                borderRadius: AppBorders.kBottom10,
                child: Assets.images.featuredSnacks.image(fit: BoxFit.cover),
              ),
              title: PageHeader(
                title: task == null
                    ? t.tasks.title
                    : t.tasks.number(number: task.number),
                goBack: () => goBack(context),
              ),
            ),
            body: SafeArea(
              top: false,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AppBoxes.kHeight16,
                  Expanded(
                    child: task == null
                        ? (state.loading
                              ? const Center(child: CircularProgressIndicator())
                              : TasksMessage(
                                  text: state.loadFailure is NetworkFailure
                                      ? t.tasks.noConnection
                                      : t.tasks.loadFailed,
                                  onRetry: cubit.refresh,
                                ))
                        : _TaskBody(state: state, task: task),
                  ),
                  if (task != null)
                    TaskActionsBar(
                      task: task,
                      busy: state.busy,
                      onTake: cubit.take,
                      onRelease: () => confirmRelease(context),
                      onExecute: () => execute(context),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Тело карточки: шапка задания, позиции, заходы.
class _TaskBody extends StatelessWidget {
  const _TaskBody({required this.state, required this.task});

  final TaskDetailState state;
  final WarehouseTask task;

  @override
  Widget build(BuildContext context) {
    final section = SemiboldTextStyles().semiboldInter16;
    final muted = RegularTextStyles().regularInter12.copyWith(
      color: AppColors.kTextMuted,
    );
    return ListView(
      padding: AppInsets.h16,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                taskKindLabel(task.kind),
                style: SemiboldTextStyles().semiboldInter14,
              ),
            ),
            TaskStatusBadge(status: task.status),
          ],
        ),
        Text(
          t.tasks.tileNumber(
            number: task.number,
            created: fullDateTime(task.createdAt),
          ),
          style: muted,
        ),
        Text(taskAuthor(task), style: muted),
        Text(taskBasis(task), style: muted),
        if (task.isMine && task.assigneeName.isNotEmpty)
          Text(t.tasks.assignee(name: task.assigneeName), style: muted),
        AppBoxes.kHeight16,
        Text(t.tasks.detailItems, style: section),
        AppBoxes.kHeight8,
        for (final item in task.items) TaskItemTile(item: item),
        AppBoxes.kHeight16,
        Text(t.tasks.detailHistory, style: section),
        AppBoxes.kHeight8,
        if (state.sessionsUnavailable)
          Text(t.tasks.detailHistoryOffline, style: muted)
        else
          for (final e in state.events)
            HistoryTile(
              event: e,
              session: state.sessions
                  .where((s) => s.putawayId == e.putawayId)
                  .firstOrNull,
            ),
        AppBoxes.kHeight16,
      ],
    );
  }
}
