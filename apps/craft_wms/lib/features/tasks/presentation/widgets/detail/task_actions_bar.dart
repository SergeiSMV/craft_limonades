import 'package:flutter/material.dart';

import '../../../../../core/constants/app_boxes.dart';
import '../../../../../core/constants/app_insets.dart';
import '../../../../../core/constants/app_sizes.dart';
import '../../../../../core/gen/strings.g.dart';
import '../../../data/tasks_models.dart';

/// Действия карточки: новое задание — «Взять в работу»; своё взятое — «Выполнить»
/// и «Отказаться». У выполненного действий нет.
class TaskActionsBar extends StatelessWidget {
  const TaskActionsBar({
    super.key,
    required this.task,
    required this.busy,
    required this.onTake,
    required this.onRelease,
    required this.onExecute,
  });

  final WarehouseTask task;
  final bool busy;
  final VoidCallback onTake;
  final VoidCallback onRelease;
  final VoidCallback onExecute;

  @override
  Widget build(BuildContext context) {
    if (task.status == TaskStatus.done) return const SizedBox.shrink();
    final progress = busy
        ? const SizedBox.square(
            dimension: AppSizes.kIcon18,
            child: CircularProgressIndicator(strokeWidth: AppSizes.kIcon2),
          )
        : null;
    return SafeArea(
      top: false,
      child: Padding(
        padding: AppInsets.all16,
        child: task.isMine
            ? Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: busy ? null : onRelease,
                      child: Text(t.tasks.release),
                    ),
                  ),
                  AppBoxes.kWidth12,
                  Expanded(
                    child: FilledButton(
                      onPressed: busy ? null : onExecute,
                      child: Text(t.tasks.execute),
                    ),
                  ),
                ],
              )
            : FilledButton(
                onPressed: busy ? null : onTake,
                child: progress ?? Text(t.tasks.take),
              ),
      ),
    );
  }
}
