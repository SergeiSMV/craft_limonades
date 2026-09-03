import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:injectable/injectable.dart';

/// injectable-модуль синхронизации: провайдит источник событий смены сети.
///
/// Отдельной зависимостью, а не `Connectivity()` внутри движка: в тестах события сети
/// подаются вручную, иначе проверить реакцию на появление связи можно было бы только
/// физическим включением Wi-Fi.
@module
abstract class SyncModule {
  @lazySingleton
  Connectivity get connectivity => Connectivity();
}
