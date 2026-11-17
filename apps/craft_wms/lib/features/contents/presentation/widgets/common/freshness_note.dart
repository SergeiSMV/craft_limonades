import 'package:flutter/material.dart';

import '../../../../../core/constants/app_colors.dart';
import '../../../../../core/constants/app_insets.dart';
import '../../../../../core/gen/strings.g.dart';
import '../../../../../core/theme/regular_text.dart';
import '../../../../../core/utils/date_time_format.dart';
import '../../../domain/contents_entities.dart';

/// Подпись «откуда данные»: не с сервера - на какой момент снимок (P5-05).
///
/// С сервера ничего не пишется: свежие данные - норма, подписывать каждую норму - шум.
/// Из снимка подпись обязательна: по устаревшему месту короба кладовщик пойдёт не туда.
/// «Нет связи» - только когда причина именно в связи (ADHOC-22): сервер, ответивший ошибкой,
/// связь не отменяет, и кладовщик не должен искать проблему с Wi-Fi там, где её нет.
class FreshnessNote extends StatelessWidget {
  const FreshnessNote({super.key, required this.freshness});

  final DataFreshness freshness;

  @override
  Widget build(BuildContext context) {
    final text = switch (freshness) {
      FreshFromServer() => null,
      FromSnapshot(asOf: final asOf?, offline: true) => t.contents.snapshotNote(
        time: shortDateTime(asOf),
      ),
      FromSnapshot(asOf: final asOf?) => t.contents.snapshotAsOf(
        time: shortDateTime(asOf),
      ),
      FromSnapshot() => t.contents.snapshotNone,
    };
    if (text == null) return const SizedBox.shrink();
    return Padding(
      padding: AppInsets.bottom8 + AppInsets.left6,
      child: Text(
        text,
        style: RegularTextStyles().regularInter12.copyWith(
          color: AppColors.kBadgeWarningText,
        ),
      ),
    );
  }
}
