import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../constants/app_colors.dart';
import '../di/injection.dart';
import '../gen/strings.g.dart';
import '../theme/semibold_text.dart';
import 'app_update_cubit.dart';

/// Кнопка «Обновить приложение» на экране входа и в главном меню (ADHOC-69).
///
/// Что: видна, только когда новая версия уже скачана в фоне. Нажатие при неотправленной
///      очереди обновление не ставит, а показывает [queueHint].
/// Зачем ещё и проверка здесь: виджет стоит только на экранах, где никто не работает, поэтому
///      он же и просит [AppUpdateCubit] проверить версию - при показе экрана, при возврате на
///      него из раздела (`didPopNext`) и при выходе приложения на передний план. Чаще раза в
///      [AppUpdateCubit.checkInterval] кубит магазин не спрашивает.
class AppUpdateButton extends StatefulWidget {
  const AppUpdateButton({super.key, required this.queueHint});

  /// Подсказка при непустой очереди: на экране входа - войти, в меню - дождаться отправки.
  final String queueHint;

  @override
  State<AppUpdateButton> createState() => _AppUpdateButtonState();
}

class _AppUpdateButtonState extends State<AppUpdateButton>
    with AutoRouteAware, WidgetsBindingObserver {
  late final AppUpdateCubit _cubit = getIt<AppUpdateCubit>();

  /// Наблюдатель маршрутов из роутера приложения; `null` - экран нарисован без роутера (тесты).
  AutoRouteObserver? _routes;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _cubit.check();
  }

  /// Подписка на возврат к экрану. Готовый `AutoRouteAwareStateMixin` не взят: он требует
  /// роутер над виджетом и падает, когда экран нарисован без него.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_routes != null) return;
    final scope = context.getInheritedWidgetOfExactType<RouterScope>();
    _routes = scope?.firstObserverOfType<AutoRouteObserver>();
    _routes?.subscribe(this, context.routeData);
  }

  @override
  void dispose() {
    _routes?.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Вернулись на этот экран из раздела - работник закончил операцию.
  @override
  void didPopNext() => _cubit.check();

  /// Приложение снова на переднем плане (терминал разбудили) - тоже повод спросить магазин.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _cubit.check();
  }

  /// Запустить установку; при непустой очереди или отказе магазина - подсказка.
  Future<void> install() async {
    final messenger = ScaffoldMessenger.of(context);
    final text = switch (await _cubit.install()) {
      AppUpdateInstallResult.started => null,
      AppUpdateInstallResult.queueNotEmpty => widget.queueHint,
      AppUpdateInstallResult.failed => t.appUpdate.failed,
    };
    if (text == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<AppUpdateCubit, AppUpdateState>(
      bloc: _cubit,
      builder: (context, state) {
        if (state == AppUpdateState.hidden) return const SizedBox.shrink();
        return TextButton(
          onPressed: state == AppUpdateState.ready ? install : null,
          child: Text(
            t.appUpdate.button,
            style: SemiboldTextStyles().semiboldInter14.copyWith(
              color: AppColors.kTileText,
              decoration: TextDecoration.underline,
              decorationColor: AppColors.kTileText,
            ),
          ),
        );
      },
    );
  }
}
