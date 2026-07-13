import 'package:get_it/get_it.dart';
import 'package:injectable/injectable.dart';

import 'injection.config.dart';

/// Глобальный сервис-локатор.
final getIt = GetIt.instance;

/// Собирает граф зависимостей (сгенерировано injectable в injection.config.dart).
/// Вызывается один раз при старте приложения (main.dart).
@InjectableInit()
void configureDependencies() => getIt.init();
