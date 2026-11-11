import 'dart:async';

import 'package:craft_wms/core/di/injection.dart';
import 'package:craft_wms/core/scanner/scan_serial.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';

/// Сканы экрана по одному (ADHOC-70): второй скан начинается, когда первый закончился, и
/// видит его результат - гонка двух быстрых сканов (одна марка дважды) невозможна.
void main() {
  setUp(() => getIt.registerSingleton<Talker>(Talker()));
  tearDown(getIt.reset);

  test('второй скан ждёт первый и видит его итог', () async {
    final serial = ScanSerial('Тест');
    final taken = <String>{};
    final log = <String>[];
    final gate = Completer<void>();

    Future<void> scan(String cis, {Future<void>? slow}) async {
      // Проверка «уже взята» и запись - как у экрана: между ними ожидание базы.
      final already = taken.contains(cis);
      await slow;
      if (already) {
        log.add('$cis: уже взята');
      } else {
        taken.add(cis);
        log.add('$cis: взята');
      }
    }

    final first = serial.run(() => scan('m1', slow: gate.future));
    final second = serial.run(() => scan('m1'));
    await Future<void>.delayed(Duration.zero);
    expect(log, isEmpty);
    gate.complete();
    await Future.wait([first, second]);
    expect(log, ['m1: взята', 'm1: уже взята']);
  });

  test('ошибка скана не останавливает следующие', () async {
    final serial = ScanSerial('Тест');
    final log = <String>[];
    await Future.wait([
      serial.run(() async => throw StateError('сбой')),
      serial.run(() async => log.add('второй')),
    ]);
    expect(log, ['второй']);
  });
}
