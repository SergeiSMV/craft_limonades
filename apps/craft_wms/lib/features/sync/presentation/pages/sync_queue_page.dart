import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/outbox/outbox_operation.dart';
import '../../../../core/outbox/outbox_repository.dart';
import '../../../../core/outbox/sent_sessions.dart';
import '../../../../core/router/app_router.dart';
import '../../../movement/domain/movement_repository.dart';
import '../../../problems/domain/problem_photos.dart';
import '../../../putaway/data/putaway_repository.dart';
import '../bloc/sync_status_cubit.dart';
import '../widgets/operation_tile.dart';
import '../widgets/sync_now_button.dart';
import '../../../../core/utils/doc_number.dart';

/// Экран несинхронизированных операций (P2-06).
///
/// Что: что ещё не уехало на сервер и что он отклонил, с причиной и разбором.
/// Зачем: до него отклонённая операция оседала в очереди молча. Кладовщик привязал ШК без
///        связи, ему сказали «отложена», а сервер потом отказал - и об этом не узнавал никто:
///        ни строки на экране, ни следа, кроме записи в базе устройства.
/// Как: два живых списка из очереди - ожидающие и отклонённые. Ожидающие уйдут сами, поэтому
///      действий над ними нет; отклонённые повтором не лечатся сами по себе, поэтому у каждой
///      две кнопки - повторить и отбросить.
///
/// Оформление служебное (стандартный Material, как у экранов логов и диагностики сканера):
/// экран живёт в том же меню в шапке и открывается не в рабочем потоке, а когда что-то пошло
/// не так.
@RoutePage()
class SyncQueuePage extends StatefulWidget {
  const SyncQueuePage({super.key});

  @override
  State<SyncQueuePage> createState() => _SyncQueuePageState();
}

class _SyncQueuePageState extends State<SyncQueuePage> {
  final OutboxRepository outbox = getIt<OutboxRepository>();

  /// Подписки на очередь заводятся ОДИН раз, а не в `build`.
  ///
  /// Поток, созданный в `build`, пересоздаётся на каждую перерисовку: старая подписка на базу
  /// отменяется, заводится новая, и так на каждый кадр. Тот же изъян, что у `Future` в `build`,
  /// и ловится он так же - тестом, который не дожидается покоя.
  late final Stream<List<OutboxOperation>> _rejected = outbox.watchRejected();
  late final Stream<List<OutboxOperation>> _pending = outbox.watchPending();

  /// Фото к проблемам идут своей очередью (ADHOC-45) - здесь только сколько их ждёт.
  late final Stream<int> _photos = getIt<ProblemPhotoRepository>()
      .watchPendingCount();

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => getIt<SyncStatusCubit>(),
      child: Builder(builder: _buildScaffold),
    );
  }

  /// Разметка экрана. Отдельным методом, чтобы кнопка отправки читала состояние из провайдера,
  /// стоящего выше неё.
  Widget _buildScaffold(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(t.syncQueue.title)),
      // Кнопка ручной отправки (P2-07). Стоит здесь, а не в шапке главного меню: сюда
      // кладовщик и приходит, когда видит, что работа не уехала, - и здесь же видит, сколько
      // именно ждёт. Кнопка в шапке заставляла бы жать вслепую.
      floatingActionButton: const SyncNowButton(),
      body: StreamBuilder<List<OutboxOperation>>(
        stream: _rejected,
        builder: (context, rejectedSnapshot) {
          final rejected = rejectedSnapshot.data ?? const <OutboxOperation>[];
          return StreamBuilder<List<OutboxOperation>>(
            stream: _pending,
            builder: (context, pendingSnapshot) {
              final pending = pendingSnapshot.data ?? const <OutboxOperation>[];
              return StreamBuilder<int>(
                stream: _photos,
                builder: (context, photosSnapshot) {
                  final photos = photosSnapshot.data ?? 0;
                  if (rejected.isEmpty && pending.isEmpty && photos == 0) {
                    return Center(child: Text(t.syncQueue.empty));
                  }
                  return _list(context, rejected, pending, photos);
                },
              );
            },
          );
        },
      ),
    );
  }

  /// Списки очереди: отклонённые, ожидающие, число фото в своей очереди.
  Widget _list(
    BuildContext context,
    List<OutboxOperation> rejected,
    List<OutboxOperation> pending,
    int photos,
  ) {
    return ListView(
      padding: AppInsets.all16,
      children: [
        // Отклонённые выше ожидающих: ожидающие уйдут сами, а эти без человека
        // не сдвинутся, и ради них экран и открывают.
        if (rejected.isNotEmpty) ...[
          _SectionTitle(t.syncQueue.rejectedTitle(count: rejected.length)),
          for (final operation in rejected)
            OperationTile(
              operation: operation,
              onRetry: () => outbox.retry(operation.operationId),
              onDiscard: () => _confirmDiscard(context, outbox, operation),
              onFix: _fixable(operation)
                  ? () => _fix(context, operation)
                  : null,
            ),
          AppBoxes.kHeight16,
        ],
        if (pending.isNotEmpty) ...[
          _SectionTitle(t.syncQueue.pendingTitle(count: pending.length)),
          for (final operation in pending) OperationTile(operation: operation),
        ],
        if (photos > 0) ...[
          AppBoxes.kHeight16,
          _SectionTitle(t.syncQueue.photosTitle(count: photos)),
        ],
      ],
    );
  }

  /// У операции есть сеанс, который можно вернуть в правку (ADHOC-41).
  bool _fixable(OutboxOperation operation) =>
      operation.kind == OutboxKind.movementSubmit ||
      operation.kind == OutboxKind.putawaySubmit;

  /// «Исправить»: отклонённый сеанс снова черновик своего раздела (ADHOC-41, долг 26).
  ///
  /// Перемещение открывается сразу. Размещение живёт внутри задания, а задание экран берёт
  /// свежим из списка - поэтому кладовщик получает номер задания и открывает его сам.
  Future<void> _fix(BuildContext context, OutboxOperation operation) async {
    final messenger = ScaffoldMessenger.of(context);
    final router = context.router;
    void say(String text) =>
        messenger.showSnackBar(SnackBar(content: Text(text)));

    if (operation.kind == OutboxKind.movementSubmit) {
      final outcome = await getIt<MovementRepository>().reopenRejected(
        operation.operationId,
      );
      switch (outcome) {
        case ReopenOutcome.reopened:
          await router.push(const MovementRoute());
        case ReopenOutcome.draftBusy:
          say(t.syncQueue.fixBusyMovement);
        case ReopenOutcome.lost:
          say(t.syncQueue.fixLost);
      }
      return;
    }
    final (outcome, number) = await getIt<PutawayRepository>().reopenRejected(
      operation.operationId,
    );
    say(switch (outcome) {
      ReopenOutcome.reopened => t.syncQueue.fixPutaway(number: docNumber(DocKind.task, number)),
      ReopenOutcome.draftBusy => t.syncQueue.fixBusyPutaway,
      ReopenOutcome.lost => t.syncQueue.fixLost,
    });
  }

  /// Отбросить операцию, спросив подтверждение: она исчезнет насовсем, а восстановить её
  /// можно только повторив саму работу - снова найти товар и отсканировать код.
  Future<void> _confirmDiscard(
    BuildContext context,
    OutboxRepository outbox,
    OutboxOperation operation,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(t.syncQueue.discardTitle),
        content: Text(t.syncQueue.discardBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(t.syncQueue.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(t.syncQueue.discardConfirm),
          ),
        ],
      ),
    );
    if (ok ?? false) await outbox.discard(operation.operationId);
  }
}

/// Заголовок раздела списка.
class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: AppInsets.bottom8,
    child: Text(text, style: Theme.of(context).textTheme.titleMedium),
  );
}
