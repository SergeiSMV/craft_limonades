import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/config/app_config.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';

/// Ссылка «Политика конфиденциальности» внизу экрана входа (ADHOC-66).
///
/// Что: открывает страницу политики во внешнем браузере устройства.
/// Зачем: правила RuStore требуют, чтобы политика приложения с персональными данными была
///        доступна не только из карточки магазина, но и внутри приложения.
/// Как: адрес — [AppConfig.privacyPolicyUrl] (страница портала на том же сервере); не открылась
///      (нет браузера, нет связи с системой) — показываем адрес текстом, чтобы его можно было
///      открыть с другого устройства.
class PrivacyPolicyLink extends StatelessWidget {
  const PrivacyPolicyLink({super.key});

  /// Открыть политику во внешнем браузере; при неудаче — адрес в подсказке снизу.
  Future<void> openPolicy(BuildContext context) async {
    final url = AppConfig.privacyPolicyUrl;
    final messenger = ScaffoldMessenger.of(context);
    var opened = false;
    try {
      opened = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      opened = false;
    }
    if (!opened) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text(t.loginScreen.privacyOpenFailed(url: url))),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: () => openPolicy(context),
      child: Text(
        t.loginScreen.privacyPolicy,
        style: RegularTextStyles().regularInter12.copyWith(
          color: AppColors.kTileText,
          decoration: TextDecoration.underline,
          decorationColor: AppColors.kTileText,
        ),
      ),
    );
  }
}
