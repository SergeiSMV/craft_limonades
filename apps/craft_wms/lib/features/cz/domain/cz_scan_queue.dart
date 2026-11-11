import 'dart:async';

import 'package:either_dart/either.dart';

import '../../../core/error/failure.dart';
import 'cz_scan.dart';

/// Код ЧЗ в очереди чтения: как пришёл со сканера, ключ ЧЗ (марка или код короба без
/// криптохвоста) и [target] - куда прочитанное ляжет, запомненное в момент скана.
class CzQueued<T> {
  const CzQueued({required this.code, required this.key, required this.target});

  final String code;
  final String key;
  final T target;
}

/// Ответ очереди по одному коду: что сканировали и что ответил ЧЗ.
class CzQueueResult<T> {
  const CzQueueResult(this.item, this.result);

  final CzQueued<T> item;
  final Either<Failure, CzScanResult> result;
}

/// Очередь чтения кодов «Честного знака» пачками (ADHOC-70).
///
/// Что: скан встаёт в очередь сразу и ответа не ждёт; коды уходят на сервер пачками
/// (`cz/scan/batch`), ответы выдаются в [results] пачкой и в порядке сканов.
/// Зачем: одна марка - один запрос в True API на 0,5-1,3 с. Кладовщик сканирует бутылки
/// подряд быстрее, и раньше каждая марка ждала своего ответа (снэк «Читаю…»).
/// Как: пока пачка читается, новые сканы копятся; закончилась - накопленное уходит
/// следующей пачкой (до [maxBatch]). Без связи пачка отдаёт отказ каждому своему коду:
/// чтение без связи невозможно, и экран говорит, сколько марок не прочитано.
class CzScanQueue<T> {
  CzScanQueue(this._repo, {this.maxBatch = 100});

  final CzScanRepository _repo;

  /// Кодов в одной пачке: предел сервера на одно чтение ЧЗ.
  final int maxBatch;

  final _waiting = <CzQueued<T>>[];
  final _reading = <CzQueued<T>>[];
  // sync: ответ доходит до экрана в тот же момент, когда коды уходят из [pending], - иначе
  // между ними был бы миг, когда «ждут ответа» ноль, а применение ещё не началось.
  final _results = StreamController<List<CzQueueResult<T>>>(sync: true);
  final _pending = StreamController<int>.broadcast();
  bool _running = false;
  Completer<void>? _idle;

  /// Ответы пачками, в порядке сканов. Подписчик один - экран прихода; до подписки ответы
  /// копятся.
  Stream<List<CzQueueResult<T>>> get results => _results.stream;

  /// Сколько кодов ждут ответа: при каждом изменении.
  Stream<int> get pendingChanges => _pending.stream;

  /// Сколько кодов ждут ответа (в очереди и в чтении).
  int get pending => _waiting.length + _reading.length;

  /// Код с этим ключом уже ждёт ответа - повтор читать незачем.
  bool holds(String key) =>
      _waiting.any((q) => q.key == key) || _reading.any((q) => q.key == key);

  /// Поставить код в очередь и запустить чтение, если оно стоит.
  void add(CzQueued<T> item) {
    _waiting.add(item);
    _notify();
    unawaited(_pump());
  }

  /// Дождаться, пока все поставленные коды прочитаны и отданы в [results].
  Future<void> whenIdle() {
    if (!_running && _waiting.isEmpty) return Future.value();
    return (_idle ??= Completer<void>()).future;
  }

  /// Читать, пока есть что: пачка за пачкой.
  Future<void> _pump() async {
    if (_running) return;
    _running = true;
    try {
      while (_waiting.isNotEmpty) {
        final take = _waiting.length < maxBatch ? _waiting.length : maxBatch;
        _reading.addAll(_waiting.take(take));
        _waiting.removeRange(0, take);
        final batch = await _read(List.of(_reading));
        if (!_results.isClosed) _results.add(batch);
        _reading.clear();
        _notify();
      }
    } finally {
      _running = false;
      final idle = _idle;
      _idle = null;
      idle?.complete();
    }
  }

  /// Прочитать пачку. Ответ сопоставляется по порядку: сервер отвечает на каждый код в том
  /// же порядке; недостающий ответ - отказ этого кода, а не сдвиг чужих.
  Future<List<CzQueueResult<T>>> _read(List<CzQueued<T>> batch) async {
    final res = await _repo.scanMany([for (final q in batch) q.code]);
    if (res.isLeft) {
      return [for (final q in batch) CzQueueResult(q, Left(res.left))];
    }
    final items = res.right;
    return [
      for (var i = 0; i < batch.length; i++)
        CzQueueResult(
          batch[i],
          i < items.length ? items[i].result : const Left(Failure.unknown()),
        ),
    ];
  }

  void _notify() {
    if (!_pending.isClosed) _pending.add(pending);
  }

  /// Закрыть очередь вместе с экраном. Чтение в полёте доработает, но ответ уже никому.
  void dispose() {
    unawaited(_results.close());
    unawaited(_pending.close());
  }
}
