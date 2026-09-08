import 'package:flutter/material.dart';

import '../../features/stock_entry/data/entry_draft_store.dart';
import '../constants/app_sizes.dart';
import '../di/injection.dart';
import '../gen/strings.g.dart';
import 'notification_badge.dart';

/// Есть ли на устройстве незавершённый проход ввода остатков (ADHOC-13).
///
/// Что: источник признака, отдельно от того, как он рисуется.
/// Зачем: пометка нужна в двух непохожих местах — плитке меню, которая рисует её сама
///        (`MenuTile.showBadge`), и голой иконке в шапке «Остатков», которую надо обернуть.
///        Обёртка, годная для иконки, для плитки не годится: плитка занимает всю ячейку сетки,
///        и кружок, подвешенный снаружи, уезжает в зазор между плитками.
/// Зачем вообще: просчитанные ячейки лежат в своей таблице и в очередь операций не попадают,
///        поэтому индикатор синхронизации (P2-07) их не видит — на устройстве может ждать обход
///        всего склада, а шапка показывает «всё отправлено».
///
/// ⚠ Подписка заводится ОДИН раз, а не в `build`: поток, созданный там, пересоздаётся на каждый
/// кадр, и на устройстве это непрерывный поток запросов к локальной базе (ловилось в P2-06).
class PendingPassBuilder extends StatefulWidget {
  const PendingPassBuilder({super.key, required this.builder});

  /// `hasPass` — есть незавершённый проход.
  final Widget Function(BuildContext context, bool hasPass) builder;

  @override
  State<PendingPassBuilder> createState() => _PendingPassBuilderState();
}

class _PendingPassBuilderState extends State<PendingPassBuilder> {
  late final Stream<bool> _hasPass = getIt<EntryDraftStore>().watchHasDraft();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<bool>(
      stream: _hasPass,
      // До первого значения пометки нет: мигнуть ею на пустом проходе хуже, чем показать
      // кадром позже.
      builder: (context, snapshot) =>
          widget.builder(context, snapshot.data ?? false),
    );
  }
}

/// Пометка незавершённого прохода поверх произвольного входа — для тех мест, где нет своего
/// слота под неё (иконка «Ввод остатков» в шапке «Остатков»).
///
/// Плитки меню пользуются `MenuTile.showBadge`, а не этой обёрткой.
class PendingPassBadge extends StatelessWidget {
  const PendingPassBadge({super.key, required this.child});

  /// Вход в раздел, который помечаем.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return PendingPassBuilder(
      builder: (context, hasPass) {
        if (!hasPass) return child;
        return Tooltip(
          message: t.stockEntry.pendingPassHint,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              child,
              Positioned(
                top: -AppSizes.kIcon4,
                right: -AppSizes.kIcon4,
                child: const NotificationBadge(size: AppSizes.kIcon16),
              ),
            ],
          ),
        );
      },
    );
  }
}
