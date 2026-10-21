import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../core/auth/auth_cubit.dart';
import '../core/constants/app_boxes.dart';
import '../core/constants/app_colors.dart';
import '../core/constants/app_sizes.dart';
import '../core/di/injection.dart';
import '../core/gen/assets.gen.dart';
import '../core/gen/strings.g.dart';
import '../core/theme/app_theme.dart';
import 'presentation/pages/portal_login_page.dart';
import 'presentation/pages/portal_shell.dart';

/// Корневой виджет веб-портала. Экран выбирается по состоянию входа (единое место правды):
/// unknown (идёт восстановление сессии) → загрузка; вошли admin → оболочка портала;
/// вошли не-admin → отказ (MVP admin-only); иначе → форма входа.
class PortalApp extends StatelessWidget {
  PortalApp({super.key});

  final AuthCubit _authCubit = getIt<AuthCubit>();

  @override
  Widget build(BuildContext context) {
    return BlocProvider.value(
      value: _authCubit,
      child: MaterialApp(
        title: t.portal.appTitle,
        debugShowCheckedModeBanner: false,
        theme: buildPortalTheme(),
        // Русские системные виджеты портала: календарь, подсказки, меню выделения (ADHOC-30).
        locale: const Locale('ru'),
        supportedLocales: const [Locale('ru')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: BlocBuilder<AuthCubit, AuthState>(
          builder: (context, state) => switch (state) {
            AuthAuthenticated(:final profile) =>
              profile.role == 'admin'
                  ? PortalShell(profile: profile)
                  : const _AdminOnlyView(),
            // unknown — тихое восстановление сессии при старте (не мигаем формой входа).
            AuthUnknown() => const _LoadingView(),
            // unauthenticated / authenticating — форма входа сама показывает спиннер на кнопке.
            _ => const PortalLoginPage(),
          },
        ),
      ),
    );
  }
}

/// Индикатор загрузки на всё окно (восстановление сессии при старте).
///
/// Что: логотип + вращающаяся картинка loading.
/// Зачем: визуальный фидбек, пока AuthCubit восстанавливает сессию.
/// Как: AnimationController.repeat() крутит RotationTransition вокруг loading-ассета.
class _LoadingView extends StatefulWidget {
  const _LoadingView();

  @override
  State<_LoadingView> createState() => _LoadingViewState();
}

class _LoadingViewState extends State<_LoadingView>
    with SingleTickerProviderStateMixin {
  /// Два оборот за секунду — достаточно заметно, без «дёрганья».
  static const _spinDuration = Duration(seconds: 2);

  /// Контроллер анимации вращения.
  late final AnimationController _spinController;

  @override
  void initState() {
    super.initState();
    _spinController = AnimationController(vsync: this, duration: _spinDuration)
      ..repeat();
  }

  @override
  void dispose() {
    _spinController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.kSidebarBg,
      body: Center(
        child: SingleChildScrollView(
          child: Column(
            children: [
              Assets.images.logoAlpha.image(
                width: AppSizes.kIcon256,
                color: AppColors.kPrimary,
              ),
              RotationTransition(
                turns: _spinController,
                child: Assets.images.loading.image(
                  width: AppSizes.kIcon64,
                  height: AppSizes.kIcon64,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Отказ в доступе для не-admin (MVP admin-only; роль operator — отдельной задачей).
class _AdminOnlyView extends StatelessWidget {
  const _AdminOnlyView();

  /// Выход — вернёт форму входа.
  void _logout(BuildContext context) => context.read<AuthCubit>().logout();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.block, size: AppSizes.kIcon64, color: Colors.grey),
            AppBoxes.kHeight16,
            Text(
              t.portal.adminOnly.title,
              style: const TextStyle(
                fontSize: AppSizes.kText20,
                fontWeight: FontWeight.w600,
              ),
            ),
            AppBoxes.kHeight8,
            Text(
              t.portal.adminOnly.subtitle,
              style: const TextStyle(
                fontSize: AppSizes.kText14,
                color: Colors.grey,
              ),
            ),
            AppBoxes.kHeight24,
            OutlinedButton(
              onPressed: () => _logout(context),
              child: Text(t.portal.adminOnly.logout),
            ),
          ],
        ),
      ),
    );
  }
}
