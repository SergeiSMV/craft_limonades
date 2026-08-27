import 'package:craft_wms/core/utils/barcode.dart';
import 'package:flutter_test/flutter_test.dart';

/// Отличаем скан ШК от набранного руками текста в строке поиска (P-FS-16).
void main() {
  test('цифры длиной от 8 знаков — это ШК', () {
    expect(looksLikeBarcode('4607044662964'), isTrue); // EAN-13
    expect(looksLikeBarcode('46070446'), isTrue); // EAN-8
    expect(
      looksLikeBarcode('  4607044662964  '),
      isTrue,
    ); // с пробелами от сканера
  });

  test('текст и короткие числа — не ШК', () {
    expect(looksLikeBarcode('арахис'), isFalse);
    expect(looksLikeBarcode('15567'), isFalse); // код номенклатуры 1С короче 8
    expect(looksLikeBarcode('4607044662964x'), isFalse);
    expect(looksLikeBarcode(''), isFalse);
  });
}
