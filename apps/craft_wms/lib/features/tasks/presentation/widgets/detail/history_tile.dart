import 'package:flutter/material.dart';

import '../../../../../core/constants/app_colors.dart';
import '../../../../../core/constants/app_insets.dart';
import '../../../../../core/gen/strings.g.dart';
import '../../../../../core/printer/load_unit_label.dart';
import '../../../../../core/theme/regular_text.dart';
import '../../../../../core/theme/semibold_text.dart';
import '../../../data/tasks_models.dart';
import '../common/task_format.dart';

/// Запись «Истории выполнения»: событие журнала задания — что, кто и когда. У захода под
/// событием — что и откуда → куда переносили.
class HistoryTile extends StatelessWidget {
  const HistoryTile({super.key, required this.event, this.session});

  final TaskEvent event;

  /// Заход, о котором событие (только у [TaskEventKind.session]).
  final TaskSession? session;

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
            '${shortDateTime(event.at)} · ${_label()}',
            style: SemiboldTextStyles().semiboldInter12,
          ),
          if (session != null)
            for (final l in session!.lines)
              Text(
                '${_what(l)} · ${t.tasks.sessionLine(from: l.from, to: l.to)}',
                style: muted,
              ),
        ],
      ),
    );
  }

  String _label() => switch (event.event) {
    TaskEventKind.created =>
      event.user.isEmpty
          ? t.tasks.eventCreatedAuto
          : t.tasks.eventCreated(user: event.user),
    TaskEventKind.taken => t.tasks.eventTaken(user: event.user),
    TaskEventKind.released => t.tasks.eventReleased(user: event.user),
    TaskEventKind.intercepted => t.tasks.eventIntercepted(
      user: event.user,
      prev: event.prevUser,
    ),
    TaskEventKind.session => t.tasks.eventSession(user: event.user),
    TaskEventKind.completed => t.tasks.eventCompleted,
    _ => event.event,
  };

  String _what(TaskSessionLine l) => l.loadUnitId != null
      ? t.tasks.box(code: LoadUnitLabel(l.loadUnitId!).shortCodeFormatted)
      : '${l.good?.name ?? ''} ${qtyText(l.qty)} ${l.good?.uom ?? ''}';
}
