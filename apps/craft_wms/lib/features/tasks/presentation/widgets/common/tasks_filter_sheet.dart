import 'package:flutter/material.dart';

import '../../../../../core/constants/app_boxes.dart';
import '../../../../../core/constants/app_colors.dart';
import '../../../../../core/constants/app_insets.dart';
import '../../../../../core/constants/app_sizes.dart';
import '../../../../../core/gen/strings.g.dart';
import '../../../../../core/theme/regular_text.dart';
import '../../../../../core/theme/semibold_text.dart';
import '../../../data/tasks_models.dart';
import 'task_format.dart';

/// Открыть лист фильтра заданий. Возвращает выбранный фильтр или null, если лист закрыли.
///
/// [kindOnly] — только вид задания: так фильтруются «Текущие» (период и исполнитель им
/// пока не нужны — задание текущее, пока его не выполнили).
Future<CompletedFilter?> showTasksFilterSheet(
  BuildContext context, {
  required CompletedFilter current,
  List<TaskUser> executors = const [],
  bool kindOnly = false,
}) => showModalBottomSheet<CompletedFilter>(
  backgroundColor: AppColors.kNeumorphicBg,
  context: context,
  isScrollControlled: true,
  builder: (_) => _TasksFilterSheet(
    current: current,
    executors: executors,
    kindOnly: kindOnly,
  ),
);

/// Лист фильтра заданий: период (быстрые и произвольный), исполнитель, вид задания.
/// Условия собираются в черновик и применяются кнопкой — список обновляется один раз,
/// а не на каждое касание.
class _TasksFilterSheet extends StatefulWidget {
  const _TasksFilterSheet({
    required this.current,
    required this.executors,
    required this.kindOnly,
  });

  final CompletedFilter current;
  final List<TaskUser> executors;
  final bool kindOnly;

  @override
  State<_TasksFilterSheet> createState() => _TasksFilterSheetState();
}

class _TasksFilterSheetState extends State<_TasksFilterSheet> {
  late CompletedFilter _draft = widget.current;

  DateTime get _today {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  /// Быстрый период: последние [days] дней, включая сегодня.
  void setLastDays(int days) => setState(
    () => _draft = _draft.copyWith(
      from: _today.subtract(Duration(days: days - 1)),
      to: _today,
    ),
  );

  /// Выбрать границу периода в календаре.
  Future<void> pickDate({required bool isFrom}) async {
    final initial = (isFrom ? _draft.from : _draft.to) ?? _today;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2026),
      lastDate: _today,
    );
    if (picked == null || !mounted) return;
    setState(
      () => _draft = isFrom
          ? _draft.copyWith(from: picked)
          : _draft.copyWith(to: picked),
    );
  }

  /// Выбрать исполнителя (null — все).
  void setExecutor(String? id) => setState(
    () => _draft = _draft.copyWith(
      executor: widget.executors.where((u) => u.id == id).firstOrNull,
    ),
  );

  /// Выбрать вид задания (null — все).
  void setKind(String? kind) =>
      setState(() => _draft = _draft.copyWith(kind: kind));

  /// Сбросить все условия и применить.
  void reset() => Navigator.of(context).pop(const CompletedFilter());

  /// Применить черновик.
  void apply() => Navigator.of(context).pop(_draft);

  String _dateText(DateTime? d) => d == null
      ? t.tasks.filterAny
      : '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';

  @override
  Widget build(BuildContext context) {
    final label = SemiboldTextStyles().semiboldInter14;
    return SafeArea(
      child: Padding(
        padding:
            AppInsets.all16 +
            EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              t.tasks.filterTitle,
              style: SemiboldTextStyles().semiboldInter18,
            ),
            AppBoxes.kHeight16,
            if (!widget.kindOnly) ...[
              Text(t.tasks.filterPeriod, style: label),
              AppBoxes.kHeight8,
              Wrap(
                spacing: AppSizes.kChipSpacing,
                children: [
                  ActionChip(
                    label: Text(t.tasks.filterToday),
                    onPressed: () => setLastDays(1),
                  ),
                  ActionChip(
                    label: Text(t.tasks.filterWeek),
                    onPressed: () => setLastDays(7),
                  ),
                  ActionChip(
                    label: Text(t.tasks.filterMonth),
                    onPressed: () => setLastDays(30),
                  ),
                ],
              ),
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => pickDate(isFrom: true),
                      child: Text(
                        '${t.tasks.filterFrom} ${_dateText(_draft.from)}',
                      ),
                    ),
                  ),
                  Expanded(
                    child: TextButton(
                      onPressed: () => pickDate(isFrom: false),
                      child: Text(
                        '${t.tasks.filterTo} ${_dateText(_draft.to)}',
                      ),
                    ),
                  ),
                ],
              ),
              AppBoxes.kHeight8,
              Text(t.tasks.filterExecutor, style: label),
              DropdownButton<String?>(
                isExpanded: true,
                value: _draft.executor?.id,
                items: [
                  DropdownMenuItem(value: null, child: Text(t.tasks.filterAll)),
                  for (final u in widget.executors)
                    DropdownMenuItem(value: u.id, child: Text(u.fullName)),
                ],
                onChanged: setExecutor,
              ),
              AppBoxes.kHeight8,
            ],
            Text(t.tasks.filterKind, style: label),
            DropdownButton<String?>(
              isExpanded: true,
              value: _draft.kind,
              items: [
                DropdownMenuItem(value: null, child: Text(t.tasks.filterAll)),
                for (final k in TaskKind.all)
                  DropdownMenuItem(value: k, child: Text(taskKindLabel(k))),
              ],
              onChanged: setKind,
            ),
            AppBoxes.kHeight16,
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: reset,
                    child: Text(
                      t.tasks.filterReset,
                      style: RegularTextStyles().regularInter14,
                    ),
                  ),
                ),
                AppBoxes.kWidth12,
                Expanded(
                  child: FilledButton(
                    onPressed: apply,
                    child: Text(t.tasks.filterApply),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
