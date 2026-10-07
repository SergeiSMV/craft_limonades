import 'package:flutter/material.dart';

import '../../../../../core/constants/app_colors.dart';
import '../../../../../core/constants/app_insets.dart';
import '../../../../../core/gen/strings.g.dart';
import '../../../../../core/printer/load_unit_label.dart';
import '../../../../../core/theme/regular_text.dart';
import '../../../../../core/theme/semibold_text.dart';
import '../../../data/tasks_models.dart';
import '../common/task_format.dart';

/// Заход по заданию: кто и когда, что и откуда → куда переносил.
class SessionTile extends StatelessWidget {
  const SessionTile({super.key, required this.session});

  final TaskSession session;

  @override
  Widget build(BuildContext context) {
    final muted = RegularTextStyles().regularInter12.copyWith(
      color: AppColors.kTextMuted,
    );
    return Padding(
      padding: AppInsets.v4,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${session.user.fullName} · ${shortDateTime(session.postedAt)}',
            style: SemiboldTextStyles().semiboldInter12,
          ),
          for (final l in session.lines)
            Text(
              '${_what(l)} · ${t.tasks.sessionLine(from: l.from, to: l.to)}',
              style: muted,
            ),
        ],
      ),
    );
  }

  String _what(TaskSessionLine l) => l.loadUnitId != null
      ? t.tasks.box(code: LoadUnitLabel(l.loadUnitId!).shortCodeFormatted)
      : '${l.good?.name ?? ''} ${qtyText(l.qty)} ${l.good?.uom ?? ''}';
}
