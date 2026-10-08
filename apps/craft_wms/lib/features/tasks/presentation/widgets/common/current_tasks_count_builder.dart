import 'package:flutter/widgets.dart';

import '../../../../../core/di/injection.dart';
import '../../../data/tasks_repository.dart';

/// Число текущих заданий для плитки «ЗАДАНИЯ» на главном экране (P5-02-1).
///
/// Что: показывает число из снимка на терминале и при появлении обновляет снимок с сервера.
/// Зачем снимок: счётчик должен быть и без связи — кладовщик видит, что работа есть, ещё
/// до того, как открыл раздел. Обновление при каждом открытии главного экрана подтягивает
/// новые задания от свежих приёмок; раздел «Задания» обновляет тот же снимок сам.
class CurrentTasksCountBuilder extends StatefulWidget {
  const CurrentTasksCountBuilder({super.key, required this.builder});

  final Widget Function(BuildContext context, int count) builder;

  @override
  State<CurrentTasksCountBuilder> createState() =>
      _CurrentTasksCountBuilderState();
}

class _CurrentTasksCountBuilderState extends State<CurrentTasksCountBuilder> {
  final _repo = getIt<TasksRepository>();
  late final Stream<int> _count = _repo.watchCurrentCount();

  @override
  void initState() {
    super.initState();
    // Без связи запрос просто не удастся, а счётчик останется по снимку.
    _repo.current();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<int>(
      stream: _count,
      builder: (context, snapshot) =>
          widget.builder(context, snapshot.data ?? 0),
    );
  }
}
