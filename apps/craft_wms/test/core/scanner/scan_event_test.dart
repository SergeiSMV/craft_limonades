import 'package:craft_wms/core/scanner/scan_code.dart';
import 'package:craft_wms/core/scanner/scan_event.dart';
import 'package:flutter_test/flutter_test.dart';

/// Разбор ответов платформенного канала. Канал отдаёт нетипизированные карты,
/// и от этого разбора зависит, увидит ли приложение скан вообще.
void main() {
  group('RawScanEvent.fromChannel', () {
    test('полное событие разбирается в доменный скан', () {
      final event = RawScanEvent.fromChannel(<Object?, Object?>{
        'action': 'android.intent.ACTION_DECODE_DATA',
        'code': '4607091380001',
        'symbology': '11',
        'extras': <Object?, Object?>{
          'barcode_string': '4607091380001',
          'length': 13,
        },
      });
      expect(event.action, 'android.intent.ACTION_DECODE_DATA');
      expect(event.extras['length'], '13'); // значения приводим к строке
      expect(event.scan, isNotNull);
      expect(event.scan!.raw, '4607091380001');
      expect(event.scan!.kind, ScanKind.good);
    });

    test(
      'событие без полезной нагрузки не даёт скана, но сохраняет extras',
      () {
        final event = RawScanEvent.fromChannel(<Object?, Object?>{
          'action': 'android.intent.ACTION_DECODE_DATA',
          'extras': <Object?, Object?>{'decode_time': 42},
        });
        expect(event.scan, isNull);
        expect(event.extras, containsPair('decode_time', '42'));
      },
    );
  });

  group('ScannerProbe.fromChannel', () {
    test('признаки устройства разбираются полностью', () {
      final probe = ScannerProbe.fromChannel(<Object?, Object?>{
        'available': true,
        'packages': <Object?>['com.ubx.uscanner'],
        'manufacturer': 'UBX',
        'brand': 'UROVO',
        'model': 'DT50',
        'device': 'DT50S',
        'actions': <Object?>['android.intent.ACTION_DECODE_DATA'],
      });
      expect(probe.available, isTrue);
      expect(probe.packages, ['com.ubx.uscanner']);
      // Производитель и бренд на DT50S расходятся — сохраняем оба как есть.
      expect(probe.manufacturer, 'UBX');
      expect(probe.brand, 'UROVO');
      expect(probe.model, 'DT50');
    });

    test(
      'пустой ответ канала не роняет разбор — устройство считается без сканера',
      () {
        final probe = ScannerProbe.fromChannel(const <Object?, Object?>{});
        expect(probe.available, isFalse);
        expect(probe.packages, isEmpty);
        expect(probe.manufacturer, '');
      },
    );
  });
}
