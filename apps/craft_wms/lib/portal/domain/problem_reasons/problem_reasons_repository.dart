import 'package:either_dart/either.dart';

import '../../../core/error/failure.dart';
import '../../../core/problems/problem_reasons.dart';

/// Справочник целиком: причины и варианты решения, и неактивные.
typedef ProblemReasonsDirectory = ({
  List<ProblemReason> reasons,
  List<ResolutionVariant> resolutions,
});

/// Справочник причин проблем и вариантов решения в портале (ADHOC-55): чтение и ведение -
/// право «Настройки: причины проблем». Удаления нет - причина и вариант выключаются.
///
/// Ошибки по существу (повтор названия, системная причина, «пересорт» не у пересорта) сервер
/// объясняет текстом в поле `error` - он приезжает в `ServerFailure.message`.
///
/// Контракт для экранов портала (`dev.md §2`, ADHOC-71); реализация - `ProblemReasonsRepositoryImpl` в `data`.
abstract interface class ProblemReasonsRepository {
  /// Весь справочник.
  Future<Either<Failure, ProblemReasonsDirectory>> list();

  /// Завести причину.
  Future<Either<Failure, void>> createReason({
    required String name,
    required bool commentRequired,
    required List<String> resolutions,
  });

  /// Изменить причину; `null` - поле не меняется.
  Future<Either<Failure, void>> updateReason(
    String code, {
    String? name,
    bool? commentRequired,
    bool? isActive,
    List<String>? resolutions,
  });

  /// Завести вариант решения: название и действие.
  Future<Either<Failure, void>> createResolution({
    required String name,
    required String action,
  });

  /// Переименовать вариант и (или) выключить или включить его.
  Future<Either<Failure, void>> updateResolution(
    String id, {
    String? name,
    bool? isActive,
  });
}
