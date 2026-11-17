import 'package:craft_wms/core/scanner/scan_code.dart';
import 'package:craft_wms/core/scanner/scan_router.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';

import '../support/fake_scanner_service.dart';

/// Получатель кодов для теста: помнит, что взял, и умеет отказываться.
class _Consumer implements ScanConsumer {
  _Consumer({this.ready = true, this.takes = true});

  /// Готов принимать (аналог «виджет в дереве и верхний в стопке»).
  bool ready;

  /// Берёт код себе. `false` - отказывается, код идёт дальше по стопке.
  bool takes;

  final List<String> received = [];

  @override
  bool get canAcceptScan => ready;

  @override
  bool acceptScan(ScanCode code) {
    if (!takes) return false;
    received.add(code.raw);
    return true;
  }
}

/// Раздача кодов сканера подписчикам (ADHOC-08).
///
/// До роутера каждый экран слушал поток сам и сам решал, его ли это код. Правило «мой ли скан»
/// жило в каждом подписчике, а случая «код не взял никто» не существовало - скан исчезал
/// бесследно, что и наблюдалось в диалогах (ADHOC-07).
void main() {
  late FakeScannerService scanner;
  late Talker talker;
  late ScanRouter router;

  setUp(() {
    scanner = FakeScannerService();
    talker = Talker();
    router = ScanRouter(scanner, talker);
  });

  tearDown(() => scanner.dispose());

  /// Отдать код в поток и дать раздаче пройти.
  Future<void> emit(String code) async {
    scanner.emit(code);
    await Future<void>.delayed(Duration.zero);
  }

  test('код достаётся верхнему получателю, а не всем сразу', () async {
    final screen = _Consumer();
    final dialog = _Consumer();
    router.register(screen);
    router.register(dialog); // диалог смонтирован позже - он верхний

    await emit('4607044662964');

    expect(dialog.received, ['4607044662964']);
    expect(
      screen.received,
      isEmpty,
      reason: 'иначе стопка обработала бы один скан дважды',
    );
  });

  test('после закрытия верхнего код возвращается нижнему', () async {
    final screen = _Consumer();
    final dialog = _Consumer();
    router.register(screen);
    router.register(dialog);
    router.unregister(dialog); // диалог закрыли

    await emit('4607044662964');

    expect(screen.received, ['4607044662964']);
  });

  test('неготовый получатель пропускается', () async {
    final screen = _Consumer();
    final dialog = _Consumer(ready: false);
    router.register(screen);
    router.register(dialog);

    await emit('4607044662964');

    expect(screen.received, ['4607044662964']);
  });

  test('отказавшийся получатель передаёт код дальше по стопке', () async {
    final screen = _Consumer();
    final dialog = _Consumer(takes: false);
    router.register(screen);
    router.register(dialog);

    await emit('4607044662964');

    expect(screen.received, ['4607044662964']);
  });

  // Ветка, которой раньше не было: скан, который никто не взял, исчезал бесследно - ни
  // обработки, ни следа в логе. Именно так пропадали коды в диалоге привязки ШК.
  test('невзятый скан попадает в лог, а не в тишину', () async {
    router.register(_Consumer(ready: false));

    await emit('4607044662964');

    expect(
      talker.history.any(
        (e) => (e.message ?? '').contains('Скан никем не обработан'),
      ),
      isTrue,
    );
  });

  test('без получателей поток не слушается', () async {
    final consumer = _Consumer();
    router.register(consumer);
    router.unregister(consumer);

    await emit('4607044662964');

    expect(consumer.received, isEmpty);
    expect(router.consumerCount, 0);
  });

  // Обработчик может открыть диалог или уйти с экрана, то есть изменить состав получателей
  // прямо во время обхода.
  test('получатель, регистрирующий другого, не ломает раздачу', () async {
    final opened = _Consumer();
    final screen = _ConsumerOpening(router, opened);
    router.register(screen);

    await emit('4607044662964');

    expect(screen.received, ['4607044662964']);
    expect(
      opened.received,
      isEmpty,
      reason: 'открытый диалог получит следующий скан',
    );

    await emit('4607044663442');

    expect(opened.received, ['4607044663442']);
  });
}

/// Получатель, который на скан «открывает диалог» - регистрирует ещё одного получателя.
class _ConsumerOpening extends _Consumer {
  _ConsumerOpening(this._router, this._opened);

  final ScanRouter _router;
  final _Consumer _opened;

  @override
  bool acceptScan(ScanCode code) {
    received.add(code.raw);
    _router.register(_opened);
    return true;
  }
}
