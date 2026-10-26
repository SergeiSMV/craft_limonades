import 'package:craft_wms/core/monitoring/error_reporting.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// Отправка ошибок приложения (ADHOC-47): DSN из адреса API и что пересылается из `talker`.
void main() {
  group('DSN из адреса API', () {
    test('ТСД: абсолютный адрес — тот же сервер, путь API не нужен', () {
      expect(
        ErrorReporting.dsnFor('https://craft.skogi.ru/api/v1/'),
        'https://wms@craft.skogi.ru/1',
      );
    });

    test('порт сохраняется (стенд, локальный стек)', () {
      expect(
        ErrorReporting.dsnFor('http://192.168.0.110:8090/api/v1/'),
        'http://wms@192.168.0.110:8090/1',
      );
    });

    test('портал: относительный адрес — от адреса страницы', () {
      expect(
        ErrorReporting.dsnFor(
          '/api/v1/',
          page: Uri.parse('https://craft.skogi.ru/documents?tab=1'),
        ),
        'https://wms@craft.skogi.ru/1',
      );
    });
  });

  test('из talker пересылаются исключения, но не сеть и не записи без них', () {
    expect(ErrorReportingObserver.shouldReport(StateError('сбой')), isTrue);
    expect(ErrorReportingObserver.shouldReport(null), isFalse);
    expect(
      ErrorReportingObserver.shouldReport(
        DioException(requestOptions: RequestOptions(path: '/x')),
      ),
      isFalse,
    );
  });
}
