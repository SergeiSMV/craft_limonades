import 'package:craft_wms/core/scanner/scan_deduper.dart';
import 'package:flutter_test/flutter_test.dart';

/// Отсечение дубля доставки: тот же код в пределах окна обрабатывается один раз.
/// Иначе устройство, настроенное отдавать код и в поле, и интентом, удваивало бы строку остатка.
void main() {
  final start = DateTime(2026, 9, 2, 10);

  test('первый код проходит, немедленный повтор - нет', () {
    final deduper = ScanDeduper();
    expect(deduper.allow('4607091380001', now: start), isTrue);
    expect(
      deduper.allow(
        '4607091380001',
        now: start.add(const Duration(milliseconds: 50)),
      ),
      isFalse,
    );
  });

  test('повтор за окном - это осознанный второй скан, пропускаем', () {
    final deduper = ScanDeduper();
    deduper.allow('4607091380001', now: start);
    expect(
      deduper.allow(
        '4607091380001',
        now: start.add(const Duration(milliseconds: 500)),
      ),
      isTrue,
    );
  });

  test('другой код подряд проходит всегда', () {
    final deduper = ScanDeduper();
    deduper.allow('4607091380001', now: start);
    expect(
      deduper.allow(
        '20015467',
        now: start.add(const Duration(milliseconds: 10)),
      ),
      isTrue,
    );
  });

  test('reset забывает историю', () {
    final deduper = ScanDeduper();
    deduper.allow('4607091380001', now: start);
    deduper.reset();
    expect(
      deduper.allow(
        '4607091380001',
        now: start.add(const Duration(milliseconds: 10)),
      ),
      isTrue,
    );
  });
}
