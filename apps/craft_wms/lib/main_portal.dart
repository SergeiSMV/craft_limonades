import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:talker_bloc_logger/talker_bloc_logger.dart';
import 'package:talker_flutter/talker_flutter.dart';

import 'core/auth/auth_cubit.dart';
import 'core/di/injection.dart';
import 'core/monitoring/error_reporting.dart';
import 'portal/portal_app.dart';

/// Точка входа ВЕБ-ПОРТАЛА (Flutter Web). Отдельный entry от ТСД-приложения (main.dart),
/// но на общем ядре core/ (auth, сеть, DI, модели). Сборка: `flutter build web -t lib/main_portal.dart`.
/// Ошибки портала уходят в Bugsink через тот же бэкенд (ADHOC-47).
Future<void> main() => ErrorReporting.run(ReportingApp.portal, _start);

void _start() {
  WidgetsFlutterBinding.ensureInitialized();

  // 1. Граф зависимостей (тот же get_it + injectable, что у ТСД).
  configureDependencies();

  // 2. Логи переходов bloc/cubit — в единый Talker.
  Bloc.observer = TalkerBlocObserver(talker: getIt<Talker>());

  // 3. Тихое восстановление сессии из хранилища (на вебе — браузерное): переживает reload.
  getIt<AuthCubit>().restore();

  // 4. Пользователь событий об ошибках — по состоянию входа (id и роль).
  ErrorReporting.bindAuth(getIt<AuthCubit>());

  runApp(PortalApp());
}
