import 'dart:async';
import 'dart:math';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:either_dart/either.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:injectable/injectable.dart';
import 'package:talker_flutter/talker_flutter.dart';

import '../error/failure.dart';
import '../error/failure_reason.dart';
import '../outbox/outbox_effects.dart';
import '../outbox/outbox_operation.dart';
import '../outbox/outbox_repository.dart';
import '../outbox/outbox_retry.dart';
import '../outbox/outbox_sender.dart';
import 'link_state.dart';

/// Итог одного прохода по очереди — для ручной синхронизации и её индикатора (P2-07).
class SyncResult {
  const SyncResult({
    required this.sent,
    required this.rejected,
    required this.remaining,
  });

  /// Сколько операций сервер принял.
  final int sent;

  /// Сколько отклонил по существу — их повторять бессмысленно.
  final int rejected;

  /// Сколько осталось ждать в очереди.
  final int remaining;

  /// Очередь разгребена полностью.
  bool get isDrained => remaining == 0;

  @override
  String toString() =>
      'SyncResult(отправлено $sent, отклонено $rejected, осталось $remaining)';
}

/// Движок синхронизации очереди (P2-04).
///
/// Что: разгребает очередь операций — по одной, в порядке постановки, с повторами.
/// Зачем: до него операция уходила ровно один раз, в момент вызова; не ушла — лежала
///        в очереди мёртвым грузом, потому что будить её было некому.
/// Как: [drain] проходит очередь FIFO; временная неудача останавливает проход и заводит
///      таймер с нарастающей паузой, отказ по существу выводит операцию из очереди и проход
///      продолжается. Дополнительно движок будят вход в приложение, возврат на передний план
///      и событие смены сети.
///
/// **Событие сети — только подсказка.** Источник истины о доступности сервера — сама попытка
/// отправки: на складе «Wi-Fi подключён» и «сервер отвечает» расходятся регулярно (стеллажи,
/// металл, точка доступа в другом конце). Поэтому очередь уходит и без единого события сети —
/// таймер это гарантирует, а событие лишь позволяет не ждать паузу целиком.
@lazySingleton
class SyncEngine with WidgetsBindingObserver {
  SyncEngine(
    this._outbox,
    this._sender,
    this._effects,
    this._talker,
    this._connectivity,
  );

  final OutboxRepository _outbox;
  final OutboxSender _sender;
  final OutboxEffects _effects;
  final Talker _talker;
  final Connectivity _connectivity;

  Timer? _retryTimer;
  StreamSubscription<List<ConnectivityResult>>? _networkChanges;

  /// Что известно о связи с сервером (P2-07). Меняется по фактам обмена, а не по событиям сети:
  /// см. [LinkState].
  final ValueNotifier<LinkState> _link = ValueNotifier(LinkState.unknown);

  /// Идёт ли разгрузка очереди прямо сейчас.
  ///
  /// Отдельно от [_draining]: тот — защёлка против повторного входа, а это — то, что видит
  /// экран. Состояние берётся ИЗ ДВИЖКА, а не из состояния виджета, иначе проход, запущенный
  /// автоматически (вход, событие сети, таймер), прошёл бы без индикатора — тот же изъян,
  /// который чинился в ADHOC-10 для обновления справочников.
  final ValueNotifier<bool> _syncing = ValueNotifier(false);

  /// Связь с сервером — для индикатора в шапке.
  ValueListenable<LinkState> get link => _link;

  /// Идёт ли отправка очереди — для индикатора в шапке.
  ValueListenable<bool> get syncing => _syncing;

  /// Проход уже идёт. Защита от повторного входа: разбудить движок могут одновременно вход,
  /// возврат на передний план и событие сети, а две параллельные отправки одной операции —
  /// это два запроса вместо одного.
  bool _draining = false;

  /// Движок запущен (пользователь вошёл).
  bool _running = false;

  /// Запустить: подписка на смену сети и жизненный цикл приложения + первый проход.
  /// Зовётся после успешного входа; повторный вызов ничего не ломает.
  void start() {
    if (_running) return;
    _running = true;
    WidgetsBinding.instance.addObserver(this);
    _networkChanges = _connectivity.onConnectivityChanged.listen((results) {
      final hasNetwork = results.any((r) => r != ConnectivityResult.none);
      if (hasNetwork) {
        // Сеть появилась — пробуем сразу, не дожидаясь таймера. Онлайном это ещё не считаем:
        // доказательством будет удавшийся обмен, а не наличие интерфейса.
        _talker.info('Сеть изменилась — пробуем разгрести очередь');
        unawaited(drain());
        return;
      }
      // Сети нет вовсе — единственный случай, когда о недоступности сервера можно судить
      // без попытки обмена. Показать это сразу честнее, чем ждать неудачи по таймеру.
      _link.value = LinkState.offline;
    });
    unawaited(drain());
  }

  /// Остановить: пользователь вышел. Очередь остаётся на диске — она переживает и выход,
  /// и перезапуск, и отправится под следующим входом.
  void stop() {
    if (!_running) return;
    _running = false;
    _retryTimer?.cancel();
    _retryTimer = null;
    unawaited(_networkChanges?.cancel());
    _networkChanges = null;
    // Знание о связи принадлежит сеансу: следующий пользователь не должен видеть статус,
    // добытый до его входа.
    _link.value = LinkState.unknown;
    _syncing.value = false;
    WidgetsBinding.instance.removeObserver(this);
  }

  /// Приложение вернулось на передний план — вероятная смена обстановки (кладовщик вышел
  /// из мёртвой зоны), пробуем сразу, не дожидаясь таймера.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _running) unawaited(drain());
  }

  /// Пройти очередь: отправить всё, что ждёт, в порядке постановки.
  ///
  /// Останов на первой временной неудаче — не лень, а требование порядка: «привязать ШК»
  /// и «отвязать ШК» дают разный итог в разной последовательности, и перескочить через
  /// застрявшую операцию значит применить их задом наперёд. Отказ по существу порядку не
  /// мешает — такая операция выбывает совсем, и проход продолжается.
  Future<SyncResult> drain() async {
    if (_draining) {
      return SyncResult(
        sent: 0,
        rejected: 0,
        remaining: await _outbox.pendingCount(),
      );
    }
    _draining = true;
    _syncing.value = true;
    var sent = 0;
    var rejected = 0;
    try {
      final queue = await _outbox.pending();
      for (var from = 0; from < queue.length; from += maxBatchOperations) {
        final to = min(from + maxBatchOperations, queue.length);
        final chunk = queue.sublist(from, to);
        final outcome = await _sendChunk(chunk);
        sent += outcome.sent;
        rejected += outcome.rejected;
        if (outcome.stopped) break;
      }
    } finally {
      _draining = false;
      _syncing.value = false;
    }

    final remaining = await _outbox.pendingCount();
    if (remaining == 0) {
      _retryTimer?.cancel();
      _retryTimer = null;
      // Очередь — список дел, а не журнал: отправленное больше не нужно.
      await _outbox.purgeSent();
    }
    if (sent > 0 || rejected > 0) {
      _talker.info(
        'Синхронизация: отправлено $sent, отклонено $rejected, '
        'осталось $remaining',
      );
    }
    return SyncResult(sent: sent, rejected: rejected, remaining: remaining);
  }

  /// Отправить одну операцию и довести её статус и локальные следствия до конца.
  ///
  /// Единственная реализация отправки на всё приложение: ею пользуется и проход по очереди,
  /// и репозиторий, ставящий операцию прямо сейчас. Пока путей было два, отложенная отправка
  /// не применяла локальное следствие — привязка уходила на сервер, а в карточке товара
  /// штрихкод не появлялся (найдено на устройстве, P2-06).
  Future<Either<Failure, void>> sendOne(OutboxOperation operation) async {
    // Операцию успели снять (отмена шага) — отправлять нечего, и это не ошибка.
    if (!await _outbox.markSending(operation.operationId)) {
      return const Right(null);
    }
    final res = await _sender.send(operation);
    _noteExchange(res.fold((failure) => failure, (_) => null));
    await _settle(operation, res);
    return res;
  }

  /// Отметить, что мы узнали о связи из попытки обмена.
  ///
  /// `null` — обмен удался. Иначе судим по типу отказа: временный (обрыв, таймаут, 5xx)
  /// означает недоступный сервер, а отказ по существу — наоборот, что сервер ответил и работает.
  void _noteExchange(Failure? failure) {
    if (failure == null || !isRetryable(failure)) {
      _link.value = LinkState.online;
      return;
    }
    _link.value = LinkState.offline;
  }

  /// Отправить пачку операций одним запросом и довести каждую до её статуса.
  ///
  /// Порядок соблюдается и здесь: операции разбираются в порядке очереди, и первая, у которой
  /// исхода нет или он временный, останавливает проход. Отсутствие исхода — штатный ответ
  /// сервера «до этой я не дошёл», а не потеря: он тоже прекращает разбор на первой временной
  /// неудаче, чтобы не применить «привязать» и «отвязать» задом наперёд.
  Future<_ChunkOutcome> _sendChunk(List<OutboxOperation> candidates) async {
    // Отправляем только то, что удалось забрать: между чтением очереди и захватом
    // операцию могли снять отменой шага (долг 13).
    final chunk = <OutboxOperation>[];
    for (final operation in candidates) {
      if (await _outbox.markSending(operation.operationId)) {
        chunk.add(operation);
      }
    }
    if (chunk.isEmpty) {
      return const _ChunkOutcome(sent: 0, rejected: 0, stopped: false);
    }
    final batch = await _sender.sendBatch(chunk);

    // Запрос не состоялся целиком — вся пачка возвращается в очередь.
    if (batch.isLeft) {
      final failure = batch.left;
      _noteExchange(failure);
      for (final operation in chunk) {
        await _outbox.markFailed(operation.operationId, failureReason(failure));
      }
      _scheduleRetry(chunk.first.attempts + 1);
      return const _ChunkOutcome(sent: 0, rejected: 0, stopped: true);
    }

    // Сервер ответил — он достижим. Исход отдельных операций к связи отношения не имеет:
    // отклонённая по существу операция — это работающий сервер, а не пропавшая связь.
    _link.value = LinkState.online;

    final outcomes = batch.right;
    var sent = 0;
    var rejected = 0;
    for (final operation in chunk) {
      final res = outcomes[operation.operationId];
      if (res == null) {
        // Сервер до неё не дошёл. Возвращаем в очередь и останавливаемся: следующие за ней
        // он тоже не применял, и лезть через неё нельзя.
        await _outbox.markFailed(operation.operationId, 'нет связи');
        _scheduleRetry(operation.attempts + 1);
        return _ChunkOutcome(sent: sent, rejected: rejected, stopped: true);
      }
      await _settle(operation, res);
      if (res.isRight) {
        sent++;
        continue;
      }
      if (isRetryable(res.left)) {
        return _ChunkOutcome(sent: sent, rejected: rejected, stopped: true);
      }
      rejected++;
    }
    return _ChunkOutcome(sent: sent, rejected: rejected, stopped: false);
  }

  /// Довести статус операции и её локальные следствия до конца.
  ///
  /// Единственное место, где исход отправки превращается в статус очереди и правку кэша: им
  /// пользуются и разбор пачки, и одиночная отправка из репозитория. Пока путей было два,
  /// отложенная отправка не применяла локальное следствие (P2-06).
  Future<void> _settle(
    OutboxOperation operation,
    Either<Failure, void> res,
  ) async {
    await res.fold(
      (failure) async {
        if (isRetryable(failure)) {
          await _outbox.markFailed(
            operation.operationId,
            failureReason(failure),
          );
          _scheduleRetry(operation.attempts + 1);
          return;
        }
        await _outbox.markRejected(
          operation.operationId,
          failureReason(failure),
        );
        // Сервер отказал по существу — возвращаем локальное состояние к тому, что было.
        await _effects.rollback(operation);
        _talker.warning('Операция отклонена сервером: $operation — $failure');
      },
      (_) async {
        await _outbox.markSent(operation.operationId);
        await _effects.confirm(operation);
      },
    );
  }

  /// Завести повтор через паузу, растущую с числом попыток.
  ///
  /// Пауза считается по счётчику попыток самой операции, а он лежит в базе, — значит
  /// перезапуск приложения не сбрасывает выдержку в ноль и терминал не начинает долбить
  /// недоступный сервер заново после каждого старта.
  void _scheduleRetry(int attempts) {
    if (!_running) return;
    _retryTimer?.cancel();
    final delay = retryDelay(attempts);
    _talker.info(
      'Очередь не ушла, следующая попытка через ${delay.inSeconds} с',
    );
    _retryTimer = Timer(delay, () => unawaited(drain()));
  }
}

/// Итог разбора одной пачки: сколько ушло, сколько отклонено и нужно ли остановиться.
class _ChunkOutcome {
  const _ChunkOutcome({
    required this.sent,
    required this.rejected,
    required this.stopped,
  });

  final int sent;
  final int rejected;

  /// Проход дальше идти не должен: порядок операций важнее скорости.
  final bool stopped;
}
