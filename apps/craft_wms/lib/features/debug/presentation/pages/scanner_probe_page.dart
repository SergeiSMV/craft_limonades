import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';

import '../../../../core/constants/app_insets.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/scanner/scan_event.dart';
import '../../../../core/scanner/scanner_service.dart';
import '../widgets/scanner_probe/probe_summary_card.dart';
import '../widgets/scanner_probe/scan_event_tile.dart';

/// Служебный экран диагностики сканера (P2-01).
///
/// Что: показывает результат опроса устройства и живой поток событий декодера со всеми extras.
/// Зачем: набор и типы extras у прошивок Urovo расходятся, а проверить их можно только на живом
///        устройстве в intent-режиме - по документации не сходится. Этот экран и есть инструмент
///        такой проверки: переключил режим в настройках сканера, отсканировал, увидел сырьё.
/// Как: подписка на сырой поток [ScannerService.rawEvents]; свежие события сверху, накопленное
///      чистится кнопкой.
///
/// Оформление намеренно служебное (стандартный Material, как у экрана логов): это инструмент
/// наладки, а не рабочий экран кладовщика.
@RoutePage()
class ScannerProbePage extends StatefulWidget {
  const ScannerProbePage({super.key});

  @override
  State<ScannerProbePage> createState() => _ScannerProbePageState();
}

class _ScannerProbePageState extends State<ScannerProbePage> {
  /// Сколько событий держим на экране: диагностика - про последние сканы, а не про журнал.
  static const _maxEvents = 50;

  final _service = getIt<ScannerService>();
  final _events = <RawScanEvent>[];

  StreamSubscription<RawScanEvent>? _subscription;
  ScannerProbe _probe = ScannerProbe.none;

  @override
  void initState() {
    super.initState();
    // Опрос уже сделан при старте приложения - берём кэш, иначе спрашиваем заново.
    _probe = _service.lastProbe ?? ScannerProbe.none;
    if (_service.lastProbe == null) {
      _service.probe().then((probe) {
        if (mounted) setState(() => _probe = probe);
      });
    }
    _subscription = _service.rawEvents.listen(_onEvent);
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  /// Пришло событие декодера - кладём сверху и подрезаем хвост.
  void _onEvent(RawScanEvent event) {
    if (!mounted) return;
    setState(() {
      _events.insert(0, event);
      if (_events.length > _maxEvents) _events.removeLast();
    });
  }

  /// Очистить накопленные события.
  void clear() => setState(_events.clear);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(t.scannerProbe.title),
        actions: [
          IconButton(
            tooltip: t.scannerProbe.clear,
            onPressed: _events.isEmpty ? null : clear,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: ListView.builder(
        // +2 - сводка опроса и подсказка над списком событий.
        itemCount: _events.length + 2,
        itemBuilder: (context, index) {
          if (index == 0) return ProbeSummaryCard(probe: _probe);
          if (index == 1) return _Hint(count: _events.length);
          return ScanEventTile(event: _events[index - 2]);
        },
      ),
    );
  }
}

/// Подсказка над списком: как включить intent-режим и сколько событий уже принято.
class _Hint extends StatelessWidget {
  const _Hint({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    return Padding(
      padding: AppInsets.all12,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(t.scannerProbe.hint, style: theme.bodySmall),
          Padding(
            padding: AppInsets.top8,
            child: Text(
              count == 0
                  ? t.scannerProbe.waiting
                  : t.scannerProbe.eventsTitle(count: count),
              style: theme.titleSmall,
            ),
          ),
        ],
      ),
    );
  }
}
