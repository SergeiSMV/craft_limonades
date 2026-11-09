import 'package:either_dart/either.dart';

import '../../../core/error/failure.dart';
import 'badge_holder.dart';

/// «Бейджи» на ТСД (ADHOC-65): кого пользователь вправе печатать и номер к печати. Только со
/// связью: номер хранится на сервере зашифрованным, терминал его не кэширует.
abstract interface class BadgesRepository {
  /// Сотрудники, чьи бейджи можно печатать, по ФИО.
  Future<Either<Failure, List<BadgeHolder>>> holders();

  /// Номер бейджа сотрудника [userId] к печати.
  Future<Either<Failure, BadgeNumber>> badge(String userId);
}
