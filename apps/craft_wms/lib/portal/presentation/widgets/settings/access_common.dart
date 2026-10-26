import 'package:flutter/material.dart';

import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/error/failure.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';

/// Общее разделов «Должности» и «Пользователи» (ADHOC-50).

/// Текст ошибки: отказ по существу сервер объясняет сам.
String accessErrorText(Failure f) => switch (f) {
  ServerFailure(:final message?) => message,
  ServerFailure(:final statusCode) => t.portal.users.errorCode(
    code: statusCode,
  ),
  NetworkFailure() => t.portal.login.errorNetwork,
  _ => t.portal.login.errorUnknown,
};

/// Шапка раздела настроек: заголовок, пояснение и кнопка «Добавить». Узко — кнопка под
/// пояснением: рядом с заголовком длинная надпись кнопки не помещается.
class AccessSectionHeader extends StatelessWidget {
  const AccessSectionHeader({
    super.key,
    required this.title,
    required this.description,
    required this.action,
  });

  final String title;
  final String description;
  final Widget action;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final text = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: SemiboldTextStyles().semiboldInter20.copyWith(
              color: AppColors.kTextMain,
            ),
          ),
          AppBoxes.kHeight4,
          Text(
            description,
            style: RegularTextStyles().regularInter14.copyWith(
              color: AppColors.kTextMuted,
            ),
          ),
        ],
      );
      if (constraints.maxWidth < AppSizes.kContentMaxWidth / 2) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [text, AppBoxes.kHeight16, action],
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: text),
          AppBoxes.kWidth16,
          action,
        ],
      );
    },
  );
}

/// Подпись поля в диалоге — над группой чипов.
class AccessFieldLabel extends StatelessWidget {
  const AccessFieldLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: AppInsets.bottom8,
    child: Text(
      text,
      style: SemiboldTextStyles().semiboldInter14.copyWith(
        color: AppColors.kTextMain,
      ),
    ),
  );
}

/// Текст ошибки под списком раздела.
class AccessError extends StatelessWidget {
  const AccessError(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: RegularTextStyles().regularInter14.copyWith(
      color: AppColors.kDanger,
    ),
  );
}

/// «Отмена» — текстом и нейтральным цветом, как в диалогах складов.
Widget accessCancel(
  BuildContext ctx, {
  required String label,
  Object? result,
}) => TextButton(
  style: TextButton.styleFrom(foregroundColor: AppColors.kTextMuted),
  onPressed: () => Navigator.of(ctx).pop(result),
  child: Text(label),
);

/// Отметка в строке — пилюля, как отметки внутренних складов.
class AccessMark extends StatelessWidget {
  const AccessMark({
    super.key,
    required this.label,
    required this.bg,
    required this.fg,
  });

  final String label;
  final Color bg;
  final Color fg;

  @override
  Widget build(BuildContext context) => Container(
    padding: AppInsets.badge,
    decoration: BoxDecoration(color: bg, borderRadius: AppBorders.kPill),
    child: Text(
      label,
      style: SemiboldTextStyles().semiboldInter12.copyWith(color: fg),
    ),
  );
}
