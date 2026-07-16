import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:talker_bloc_logger/talker_bloc_logger.dart';
import 'package:talker_flutter/talker_flutter.dart';

import 'app.dart';
import 'core/auth/auth_cubit.dart';
import 'core/di/injection.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // 1. Собираем граф зависимостей (get_it + injectable).
  configureDependencies();

  // 2. Все переходы состояний bloc/cubit пишем в единый Talker (виден на экране логов).
  Bloc.observer = TalkerBlocObserver(talker: getIt<Talker>());

  // 3. Тихо восстанавливаем сессию из secure storage: состояние AuthCubit драйвит
  //    навигацию (см. app.dart), поэтому запускаем без await — UI покажет индикатор.
  getIt<AuthCubit>().restore();

  runApp(CraftWmsApp());
}
