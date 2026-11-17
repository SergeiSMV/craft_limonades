import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:talker_bloc_logger/talker_bloc_logger.dart';
import 'package:talker_flutter/talker_flutter.dart';

import 'app.dart';
import 'core/auth/auth_cubit.dart';
import 'core/config/app_mode_switch.dart';
import 'core/di/injection.dart';
import 'core/monitoring/error_reporting.dart';
import 'core/scanner/scanner_service.dart';

/// Точка входа ТСД. Ошибки приложения уходят в Bugsink (ADHOC-47): запуск обёрнут, чтобы
/// падение подготовки до первого кадра тоже дошло.
///
/// Режим (рабочий или демо, ADHOC-67) читается первым: от него зависит адрес сервера, куда
/// уходят и ошибки. Не прочитался — рабочий режим.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await AppModeSwitch.load();
  } catch (_) {
    // Хранилище недоступно — остаёмся в рабочем режиме.
  }
  await ErrorReporting.run(ReportingApp.tsd, _start);
}

Future<void> _start() async {
  WidgetsFlutterBinding.ensureInitialized(); 

  // 1. Только портретная ориентация. ТСД держат вертикально, ландшафта в работе кладовщика нет,
  //    а автоповорот срабатывает, когда терминал просто кладут на стол: экраны свёрстаны под
  //    портрет и в ландшафте рвутся переполнением (проверено на DT50S — экран входа терял 128 px).
  //    Дешевле убрать несуществующий сценарий, чем поддерживать вторую раскладку на всех экранах.
  //    Тот же портрет закреплён в AndroidManifest.xml: этот вызов срабатывает уже после старта
  //    движка, и без манифеста при запуске мелькал ландшафт (долг 5).
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

  // 2. Собираем граф зависимостей (get_it + injectable).
  configureDependencies();

  // 3. Все переходы состояний bloc/cubit пишем в единый Talker (виден на экране логов).
  Bloc.observer = TalkerBlocObserver(talker: getIt<Talker>());

  // 4. Опрашиваем устройство: есть ли аппаратный сканер. Ждём результат до первого кадра —
  //    экран входа выбирает по нему форму (скан бейджа или логин/пароль), и асинхронный ответ
  //    дал бы мелькание одной формы поверх другой. Вызов локальный и быстрый.
  await getIt<ScannerService>().probe();

  // 5. Тихо восстанавливаем сессию из secure storage: состояние AuthCubit драйвит
  //    навигацию (см. app.dart), поэтому запускаем без await — UI покажет индикатор.
  getIt<AuthCubit>().restore();

  // 6. Пользователь событий об ошибках — по состоянию входа (id и роль).
  ErrorReporting.bindAuth(getIt<AuthCubit>());

  runApp(CraftWmsApp());
}
