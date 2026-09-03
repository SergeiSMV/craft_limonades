import 'package:injectable/injectable.dart';
import 'package:uuid/uuid.dart';

/// injectable-модуль очереди операций: провайдит генератор UUID.
///
/// Отдельный модуль, а не `Uuid()` внутри репозитория: в тестах генератор подменяется на
/// предсказуемый, иначе проверить, что операция ушла в очередь под конкретным `operation_id`,
/// можно было бы только через «что-нибудь непустое».
@module
abstract class OutboxModule {
  @lazySingleton
  Uuid get uuid => const Uuid();
}
