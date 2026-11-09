import 'package:flutter/widgets.dart';

import '../../../../core/di/injection.dart';
import '../../domain/picking_repository.dart';

/// Число заказов, которые можно собирать, - для бейджа плитки «СБОРКА» на главном экране.
///
/// Свои в работе и свободные: столько же, сколько в разделах «Мои» и «Свободные» списка.
/// Перечитывается при открытии главного экрана и с каждой загрузкой списка; без связи - свои
/// заказы на терминале.
class PickingCountBuilder extends StatefulWidget {
  const PickingCountBuilder({super.key, required this.builder});

  final Widget Function(BuildContext context, int count) builder;

  @override
  State<PickingCountBuilder> createState() => _PickingCountBuilderState();
}

class _PickingCountBuilderState extends State<PickingCountBuilder> {
  final _repo = getIt<PickingRepository>();

  @override
  void initState() {
    super.initState();
    _repo.refreshActiveCount();
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
    valueListenable: _repo.activeCount,
    builder: (context, count, _) => widget.builder(context, count),
  );
}
