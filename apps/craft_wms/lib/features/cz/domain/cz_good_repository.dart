import 'package:either_dart/either.dart';

import '../../../core/error/failure.dart';

/// Признак «маркируемый» у товара (CZ-05).
///
/// Признак ставится сам по факту — привязкой ШК из марки и принятой маркой (долг 16); здесь
/// admin исправляет ошибку. Только онлайн: правка справочника, а не работа склада, и в очередь
/// она не ставится.
abstract interface class CzGoodRepository {
  /// Сохранить признак на сервере и в кэше терминала.
  Future<Either<Failure, void>> setCzMarked({
    required String goodId,
    required bool marked,
  });
}
