import 'package:flutter/material.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/error/failure.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../ui/portal_card.dart';

/// Общее разделов настроек (ADHOC-50, плоский стиль — ADHOC-56).

/// Текст ошибки: отказ по существу сервер объясняет сам.
String accessErrorText(Failure f) => switch (f) {
  ServerFailure(:final message?) => message,
  ServerFailure(:final statusCode) => t.portal.users.errorCode(
    code: statusCode,
  ),
  NetworkFailure() => t.portal.login.errorNetwork,
  _ => t.portal.login.errorUnknown,
};

/// Карточка со списком раздела: строки через разделитель, пока список грузится — индикатор,
/// отказ сервера — последней строкой. Индикатор — только до первой загрузки: при перечитывании
/// после правки список остаётся на месте.
class SettingsListCard extends StatelessWidget {
  const SettingsListCard({
    super.key,
    required this.loading,
    required this.rows,
    this.error,
  });

  final bool loading;
  final List<Widget> rows;
  final String? error;

  @override
  Widget build(BuildContext context) => PortalCard(
    children: [
      if (loading)
        const Padding(
          padding: AppInsets.cardRow,
          child: Center(
            child: SizedBox.square(
              dimension: AppSizes.kIcon20,
              child: CircularProgressIndicator(strokeWidth: AppSizes.kIcon2),
            ),
          ),
        )
      else
        ...rows,
      if (error != null)
        Padding(padding: AppInsets.cardRow, child: AccessError(error!)),
    ],
  );
}

/// Текст ошибки — под списком раздела или в диалоге.
class AccessError extends StatelessWidget {
  const AccessError(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: RegularTextStyles().regularInter13.copyWith(
      color: AppColors.kDanger,
    ),
  );
}
