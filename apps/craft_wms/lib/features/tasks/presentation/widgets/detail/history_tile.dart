import 'package:flutter/material.dart';

import '../../../../../core/constants/app_colors.dart';
import '../../../../../core/constants/app_insets.dart';
import '../../../../../core/gen/strings.g.dart';
import '../../../../../core/printer/load_unit_label.dart';
import '../../../../../core/theme/regular_text.dart';
import '../../../domain/tasks_models.dart';
import '../common/task_format.dart';

/// Запись «Истории выполнения»: событие журнала задания - что, кто и когда. У захода под
/// событием - что и откуда → куда переносили.
class HistoryTile extends StatelessWidget {
  const HistoryTile({
    super.key,
    required this.event,
    required this.kind,
    this.session,
  });

  final TaskEvent event;

  /// Вид задания: заход размещения - «Разместил», заход возврата - «Отгрузил» (ADHOC-31).
  final String kind;

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
            style: RegularTextStyles().regularInter12,
          ),
          // Подсчёт ячейки пересчёта (ADHOC-58) - какую ячейку, своей строкой.
          if (event.event == TaskEventKind.cellCounted && event.cell.isNotEmpty)
            Text(t.tasks.cell(cell: event.cell), style: muted),
          if (session != null)
            for (final l in session!.lines) ...[
              Text(_what(l), style: muted),
              if (l.loadUnitId == null)
                Text(
                  t.tasks.qtyLine(qty: qtyText(l.qty), uom: l.good?.uom ?? ''),
                  style: muted,
                ),
              Text(
                t.tasks.sessionLine(from: l.from, to: l.to),
                style: muted,
              ),
            ],
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
    TaskEventKind.session =>
      kind == TaskKind.supplierReturn
          ? t.tasks.eventShipped(user: event.user)
          : t.tasks.eventSession(user: event.user),
    TaskEventKind.completed => t.tasks.eventCompleted,
    TaskEventKind.cellCounted => t.tasks.eventCellCounted(user: event.user),
    _ => event.event,
  };

  String _what(TaskSessionLine l) => l.loadUnitId != null
      ? t.tasks.box(code: LoadUnitLabel(l.loadUnitId!).shortCodeFormatted)
      : l.good?.name ?? '';
}
