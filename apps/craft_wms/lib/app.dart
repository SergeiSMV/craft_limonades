import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'core/auth/auth_cubit.dart';
import 'core/di/injection.dart';
import 'core/router/app_router.dart';
import 'core/sync/catalog_sync_service.dart';
import 'core/sync/data_versions_sync.dart';
import 'core/sync/sync_engine.dart';
import 'core/theme/app_theme.dart';
import 'core/widgets/printer_reconnect_banner.dart';
import 'features/problems/domain/problem_photos.dart';

/// Корневой виджет. Держит роутер и слушает состояние входа, чтобы гейтить навигацию.
class CraftWmsApp extends StatelessWidget {
  CraftWmsApp({super.key});

  /// Роутер
  final AppRouter _router = getIt<AppRouter>();

  @override
  Widget build(BuildContext context) {
    return BlocProvider.value(
      value: getIt<AuthCubit>(),
      // Навигация по состоянию аутентификации — единое место правды:
      // вошли → главное меню, вышли/протух refresh → экран входа.
      child: BlocListener<AuthCubit, AuthState>(
        listener: (context, state) {
          switch (state) {
            case AuthAuthenticated():
              _router.replaceAll([const HomeRoute()]);
              // Обновляем кэш справочников — без await: экран не должен ждать загрузку, а до
              // её конца репозиторий отдаёт прежнее содержимое кэша (P2-02). Неудача не
              // показывается: если сеть недоступна, кладовщик и так работает офлайн, а
              // причина уходит в лог.
              getIt<CatalogSyncService>().refresh();
              // Движок очереди: разгребает всё, что не ушло раньше (P2-04). Тоже без await —
              // отправка идёт фоном и экрана не касается.
              getIt<SyncEngine>().start();
              // Версии данных сервера (ADHOC-60): изменилась область — перечитать её кэш.
              getIt<DataVersionsSync>().start();
              // Очередь фото проблем (ADHOC-45): снимки, снятые до перезапуска, — сразу; дальше
              // она сама идёт вслед за проходами очереди операций.
              getIt<ProblemPhotoRepository>().upload();
            // _router.replaceAll([const SplashRoute()]);
            case AuthUnauthenticated():
              // Очередь остаётся на диске и уйдёт под следующим входом — гасим только движок.
              getIt<SyncEngine>().stop();
              getIt<DataVersionsSync>().stop();
              _router.replaceAll([const LoginRoute()]);
            // _router.replaceAll([const SplashRoute()]);
            case AuthUnknown():
            case AuthAuthenticating():
              break;
          }
        },
        child: MaterialApp.router(
          title: 'Craft WMS',
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(),
          // Наблюдатель маршрутов: кнопка обновления узнаёт о возврате в меню из раздела
          // (`didPopNext`) и проверяет новую версию (ADHOC-69).
          routerConfig: _router.config(
            navigatorObservers: () => [AutoRouteObserver()],
          ),
          // Плашка «Подключаюсь к принтеру…» поверх любого экрана: печатают из приёмки,
          // «Остатков» и карточки товара, и переподключение может идти секунды (P6-04).
          builder: (context, child) =>
              PrinterReconnectBanner(child: child ?? const SizedBox.shrink()),
          // Системные виджеты Flutter (календарь фильтра заданий, подсказки, меню копирования)
          // без этого говорят по-английски: свои строки приложения идут через slang, а эти —
          // только через локализацию Material. Приложение одноязычное, поэтому русский задан
          // явно, а не берётся из настроек терминала.
          locale: const Locale('ru'),
          supportedLocales: const [Locale('ru')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
        ),
      ),
    );
  }
}
