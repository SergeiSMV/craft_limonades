import 'package:craft_wms/core/config/app_config.dart';
import 'package:flutter_test/flutter_test.dart';

/// Адрес политики конфиденциальности (ADHOC-66) выводится из адреса API: портал и API живут на
/// одном origin, страница лежит в корне портала, а не под `/api/v1/`.
void main() {
  test('политика - privacy.html в корне сервера API', () {
    final api = Uri.parse(AppConfig.baseUrl);
    final policy = Uri.parse(AppConfig.privacyPolicyUrl);

    expect(policy.origin, api.origin);
    expect(policy.path, '/privacy.html');
  });
}
