import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/outbox/outbox_operation.dart';
import '../../../../core/outbox/outbox_repository.dart';
import '../widgets/operation_tile.dart';

/// Экран несинхронизированных операций (P2-06).
///
/// Что: что ещё не уехало на сервер и что он отклонил, с причиной и разбором.
/// Зачем: до него отклонённая операция оседала в очереди молча. Кладовщик привязал ШК без
///        связи, ему сказали «отложена», а сервер потом отказал — и об этом не узнавал никто:
///        ни строки на экране, ни следа, кроме записи в базе устройства.
/// Как: два живых списка из очереди — ожидающие и отклонённые. Ожидающие уйдут сами, поэтому
///      действий над ними нет; отклонённые повтором не лечатся сами по себе, поэтому у каждой
///      две кнопки — повторить и отбросить.
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
  /// и ловится он так же — тестом, который не дожидается покоя.
  late final Stream<List<OutboxOperation>> _rejected = outbox.watchRejected();
  late final Stream<List<OutboxOperation>> _pending = outbox.watchPending();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(t.syncQueue.title)),
      body: StreamBuilder<List<OutboxOperation>>(
        stream: _rejected,
        builder: (context, rejectedSnapshot) {
          final rejected = rejectedSnapshot.data ?? const <OutboxOperation>[];
          return StreamBuilder<List<OutboxOperation>>(
            stream: _pending,
            builder: (context, pendingSnapshot) {
              final pending = pendingSnapshot.data ?? const <OutboxOperation>[];
              if (rejected.isEmpty && pending.isEmpty) {
                return Center(child: Text(t.syncQueue.empty));
              }
              return ListView(
                padding: AppInsets.all16,
                children: [
                  // Отклонённые выше ожидающих: ожидающие уйдут сами, а эти без человека
                  // не сдвинутся, и ради них экран и открывают.
                  if (rejected.isNotEmpty) ...[
                    _SectionTitle(
                      t.syncQueue.rejectedTitle(count: rejected.length),
                    ),
                    for (final operation in rejected)
                      OperationTile(
                        operation: operation,
                        onRetry: () => outbox.retry(operation.operationId),
                        onDiscard: () =>
                            _confirmDiscard(context, outbox, operation),
                      ),
                    AppBoxes.kHeight16,
                  ],
                  if (pending.isNotEmpty) ...[
                    _SectionTitle(
                      t.syncQueue.pendingTitle(count: pending.length),
                    ),
                    for (final operation in pending)
                      OperationTile(operation: operation),
                  ],
                ],
              );
            },
          );
        },
      ),
    );
  }

  /// Отбросить операцию, спросив подтверждение: она исчезнет насовсем, а восстановить её
  /// можно только повторив саму работу — снова найти товар и отсканировать код.
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
