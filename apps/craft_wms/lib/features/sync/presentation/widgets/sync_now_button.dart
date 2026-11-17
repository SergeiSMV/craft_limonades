import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/constants/app_sizes.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/sync/sync_engine.dart';
import '../bloc/sync_status_cubit.dart';
import '../bloc/sync_status_state.dart';

/// Кнопка ручной отправки очереди (P2-07).
///
/// Что: отправить всё несинхронизированное по требованию, не дожидаясь таймера.
/// Зачем: очередь уходит сама - по таймеру, событию сети и возврату в приложение, - но пауза
///        повтора растёт до пяти минут, и кладовщик, вышедший из мёртвой зоны прямо сейчас,
///        не должен стоять и ждать её. Плюс это единственный способ проверить связь намеренно.
/// Как: зовёт проход движка и показывает его итог сообщением.
///
/// Кнопка гаснет, пока проход идёт: повторное нажатие всё равно упёрлось бы в защиту от
/// повторного входа и вернуло бы «отправлено 0» - ответ, который кладовщик прочитал бы как
/// «ничего не ушло». Та же ловушка, что чинилась в ADHOC-10 для обновления справочников.
class SyncNowButton extends StatelessWidget {
  const SyncNowButton({super.key});

  /// Отправить очередь и показать итог.
  Future<void> _syncNow(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final cubit = context.read<SyncStatusCubit>();
    if (cubit.isSyncing) return;

    final res = await cubit.syncNow();
    _snack(messenger, _describe(res));
  }

  /// Итог прохода словами.
  ///
  /// Разводим три исхода, которые кладовщик обязан различать: всё ушло, отправлять было нечего
  /// и часть застряла. Одно общее «готово» на все три означало бы, что после «готово» очередь
  /// может остаться полной.
  String _describe(SyncResult res) {
    if (res.rejected > 0) {
      return t.syncQueue.syncResultRejected(count: res.rejected);
    }
    if (!res.isDrained) {
      return t.syncQueue.syncResultStuck(count: res.remaining);
    }
    if (res.sent == 0) return t.syncQueue.syncResultNothing;
    return t.syncQueue.syncResultSent(count: res.sent);
  }

  void _snack(ScaffoldMessengerState messenger, String text) => messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<SyncStatusCubit, SyncStatusState>(
      builder: (context, state) => FloatingActionButton.extended(
        onPressed: state.syncing ? null : () => _syncNow(context),
        icon: state.syncing
            ? const SizedBox.square(
                dimension: AppSizes.kIcon20,
                child: CircularProgressIndicator(strokeWidth: AppSizes.kIcon2),
              )
            : const Icon(Icons.sync),
        label: Text(
          state.syncing ? t.syncQueue.syncRunning : t.syncQueue.syncNow,
        ),
      ),
    );
  }
}
