import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:injectable/injectable.dart';

import '../../../../core/outbox/outbox_repository.dart';
import '../../../../core/sync/sync_engine.dart';
import 'sync_status_state.dart';

/// Состояние индикатора синхронизации (P2-07).
///
/// Что: сводит четыре источника - счётчик ожидающих, счётчик отклонённых, связь и признак
/// идущей отправки - в одно состояние экрана.
/// Зачем: без него шапке пришлось бы держать два `StreamBuilder` и два
/// `ValueListenableBuilder` друг в друге, и правило «что важнее показать» разъехалось бы
/// по вложенным builder'ам вместо одного места.
/// Как: подписки заводятся один раз в конструкторе и снимаются в [close].
///
/// ⚠ Подписки НЕ создаются в `build`: поток, созданный там, пересоздаётся на каждый кадр -
/// на устройстве это непрерывный поток запросов к локальной базе. Дефект такого рода уже
/// ловили виджет-тесты в P2-06.
@injectable
class SyncStatusCubit extends Cubit<SyncStatusState> {
  SyncStatusCubit(this._outbox, this._engine) : super(const SyncStatusState()) {
    _pending = _outbox.watchPendingCount().listen(
      (count) => emit(state.copyWith(pending: count)),
    );
    _rejected = _outbox.watchRejectedCount().listen(
      (count) => emit(state.copyWith(rejected: count)),
    );
    _engine.link.addListener(_onLink);
    _engine.syncing.addListener(_onSyncing);
    // Текущие значения забираем сразу: экран, собранный посреди отправки, обязан показать её,
    // а не ждать следующего изменения.
    _onLink();
    _onSyncing();
  }

  final OutboxRepository _outbox;
  final SyncEngine _engine;

  StreamSubscription<int>? _pending;
  StreamSubscription<int>? _rejected;

  void _onLink() => emit(state.copyWith(link: _engine.link.value));

  void _onSyncing() => emit(state.copyWith(syncing: _engine.syncing.value));

  /// Отправить очередь по требованию кладовщика.
  ///
  /// Возвращает итог прохода - экран показывает его сообщением. Счётчик и признак отправки
  /// обновятся сами, через подписки: отдельно их здесь не трогаем, иначе появился бы второй
  /// источник правды о том же.
  Future<SyncResult> syncNow() => _engine.drain();

  /// Идёт ли отправка - чтобы не звать [syncNow] поверх уже идущего прохода.
  bool get isSyncing => _engine.syncing.value;

  @override
  Future<void> close() {
    _engine.link.removeListener(_onLink);
    _engine.syncing.removeListener(_onSyncing);
    _pending?.cancel();
    _rejected?.cancel();
    return super.close();
  }
}
