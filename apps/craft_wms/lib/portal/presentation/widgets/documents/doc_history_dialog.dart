import 'package:flutter/material.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../data/documents_repository.dart';
import '../ui/portal_button.dart';
import '../ui/portal_modal.dart';

/// История документа (P3-03, плоский стиль — ADHOC-56): кто и когда его сформировал, скачал,
/// отметил выполненным.
Future<void> showDocHistoryDialog(BuildContext context, List<DocEvent> events) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => PortalModal(
      title: t.portal.documents.historyTitle,
      content: events.isEmpty
          ? Text(
              t.portal.documents.historyEmpty,
              style: RegularTextStyles().regularInter13.copyWith(
                color: AppColors.kTextMuted,
              ),
            )
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [for (final e in events) _HistoryRow(event: e)],
            ),
      actions: [
        PortalButton(
          label: t.portal.documents.close,
          onPressed: () => Navigator.of(ctx).pop(),
        ),
      ],
    ),
  );
}

/// Строка истории: что произошло, когда и кто это сделал.
class _HistoryRow extends StatelessWidget {
  const _HistoryRow({required this.event});

  final DocEvent event;

  /// Человекочитаемое название события. Незнакомое показываем как есть — лучше сырой код,
  /// чем пустая строка: журнал читают, когда разбираются в расхождении.
  String get _label => switch (event.event) {
    'created' => t.portal.documents.eventCreated,
    'downloaded' => t.portal.documents.eventDownloaded,
    'done' => t.portal.documents.eventDone,
    'generation_failed' => t.portal.documents.eventGenerationFailed,
    _ => event.event,
  };

  /// Формат отметки времени: `дд.мм.гггг чч:мм` в локальной зоне.
  String _at(DateTime dt) {
    final l = dt.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(l.day)}.${two(l.month)}.${l.year} ${two(l.hour)}:${two(l.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final failed = event.event == 'generation_failed';
    return Padding(
      padding: AppInsets.bottom8,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${_at(event.createdAt)} · $_label',
            style: RegularTextStyles().regularInter13.copyWith(
              color: failed ? AppColors.kDanger : AppColors.kTextMain,
            ),
          ),
          Text(
            // Автор мог не сохраниться: события до появления журнала и системные записи.
            event.userName.isEmpty
                ? t.portal.documents.eventSystem
                : event.userName,
            style: RegularTextStyles().regularInter12.copyWith(
              color: AppColors.kTextMuted,
            ),
          ),
          if (failed && event.details.isNotEmpty)
            Text(
              event.details,
              style: RegularTextStyles().regularInter12.copyWith(
                color: AppColors.kDanger,
              ),
            ),
        ],
      ),
    );
  }
}
