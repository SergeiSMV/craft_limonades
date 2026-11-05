import 'dart:async';

import 'package:flutter/widgets.dart';

import '../di/injection.dart';
import '../sync/data_versions.dart';

/// Перечитать экран, когда на сервере изменились его данные (ADHOC-60).
///
/// Что: вызывает [onChanged], когда ответ сервера принёс новую версию одной из [domains].
/// Зачем: открытый список заданий, проблем или вкладка портала узнаёт о чужих правках при
///        ближайшем обращении к серверу, без фонового опроса.
/// Как: подписка на [DataVersions] на время жизни виджета; события за короткую паузу
///      сводятся в одно — пачка ответов (очередь операций, загрузка справочников) не вызовет
///      пачку перечитываний.
class DataVersionsListener extends StatefulWidget {
  const DataVersionsListener({
    super.key,
    required this.domains,
    required this.onChanged,
    required this.child,
    this.versions,
  });

  /// Области, от которых зависит экран — [DataDomain].
  final Set<String> domains;

  /// Перечитать данные экрана.
  final VoidCallback onChanged;

  final Widget child;

  /// Источник версий; `null` — общий из DI (подмена — для тестов).
  final DataVersions? versions;

  /// Пауза сведения событий.
  static const debounce = Duration(milliseconds: 500);

  @override
  State<DataVersionsListener> createState() => _DataVersionsListenerState();
}

class _DataVersionsListenerState extends State<DataVersionsListener> {
  StreamSubscription<Set<String>>? _sub;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    final versions = widget.versions ?? getIt<DataVersions>();
    _sub = versions.on(widget.domains).listen((_) => schedule());
  }

  /// Отложить перечитывание: новое событие в паузе переносит его, а не добавляет второе.
  void schedule() {
    _timer?.cancel();
    _timer = Timer(DataVersionsListener.debounce, () {
      if (mounted) widget.onChanged();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
