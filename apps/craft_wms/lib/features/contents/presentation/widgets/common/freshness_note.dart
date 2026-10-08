import 'package:flutter/material.dart';

import '../../../../../core/constants/app_colors.dart';
import '../../../../../core/constants/app_insets.dart';
import '../../../../../core/gen/strings.g.dart';
import '../../../../../core/theme/regular_text.dart';
import '../../../../../core/utils/date_time_format.dart';
import '../../../domain/contents_entities.dart';

/// Подпись «откуда данные»: без связи — на какой момент снимок (P5-05).
///
/// С сервера ничего не пишется: свежие данные — норма, подписывать каждую норму — шум.
/// Без связи подпись обязательна: по устаревшему месту короба кладовщик пойдёт не туда.
class FreshnessNote extends StatelessWidget {
  const FreshnessNote({super.key, required this.freshness});

  final DataFreshness freshness;

  @override
  Widget build(BuildContext context) {
    final text = switch (freshness) {
      FreshFromServer() => null,
      FromSnapshot(asOf: final asOf?) => t.contents.snapshotNote(
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
