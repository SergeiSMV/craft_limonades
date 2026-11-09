import 'package:craft_wms/core/utils/serial_lock.dart';
import 'package:flutter_test/flutter_test.dart';

/// Последовательное выполнение (ADHOC-63): по одному, в порядке вызова, ошибка цепочку не рвёт.
void main() {
  test('действия идут по одному в порядке вызова', () async {
    final lock = SerialLock();
    final log = <String>[];
    Future<void> step(String name, int ms) => lock.run(() async {
      log.add('$name+');
      await Future<void>.delayed(Duration(milliseconds: ms));
      log.add('$name-');
    });

    await Future.wait([step('a', 20), step('b', 0), step('c', 5)]);

    expect(log, ['a+', 'a-', 'b+', 'b-', 'c+', 'c-']);
  });

  test(
    'ошибка возвращается вызывающему, следующее действие выполняется',
    () async {
      final lock = SerialLock();

      final failed = lock.run<int>(() async => throw StateError('нет'));
      final next = lock.run(() async => 7);

      await expectLater(failed, throwsStateError);
      expect(await next, 7);
    },
  );
}
