import 'package:dio/dio.dart';
import 'package:either_dart/either.dart';
import 'package:injectable/injectable.dart';

import '../../core/constants/api_constants.dart';
import '../../core/error/failure.dart';
import '../../core/problems/problem_reasons.dart';

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
@lazySingleton
class ProblemReasonsRepository {
  ProblemReasonsRepository(this._dio);

  final Dio _dio;

  /// Весь справочник.
  Future<Either<Failure, ProblemReasonsDirectory>> list() => _call(() async {
    final resp = await _dio.get<Map<String, dynamic>>(ApiConst.problemReasons);
    final data = resp.data ?? const {};
    return (
      reasons: [
        for (final e in data['reasons'] as List<dynamic>? ?? const [])
          ProblemReason.fromJson(e as Map<String, dynamic>),
      ],
      resolutions: [
        for (final e in data['resolutions'] as List<dynamic>? ?? const [])
          ResolutionVariant.fromJson(e as Map<String, dynamic>),
      ],
    );
  });

  /// Завести причину.
  Future<Either<Failure, void>> createReason({
    required String name,
    required bool commentRequired,
    required List<String> resolutions,
  }) => _call(
    () => _dio.post<void>(
      ApiConst.problemReasons,
      data: {
        'name': name,
        'comment_required': commentRequired,
        'resolutions': resolutions,
      },
    ),
  );

  /// Изменить причину; `null` - поле не меняется.
  Future<Either<Failure, void>> updateReason(
    String code, {
    String? name,
    bool? commentRequired,
    bool? isActive,
    List<String>? resolutions,
  }) => _call(
    () => _dio.patch<void>(
      ApiConst.problemReasonByCode(code),
      data: {
        'name': ?name,
        'comment_required': ?commentRequired,
        'is_active': ?isActive,
        'resolutions': ?resolutions,
      },
    ),
  );

  /// Завести вариант решения: название и действие.
  Future<Either<Failure, void>> createResolution({
    required String name,
    required String action,
  }) => _call(
    () => _dio.post<void>(
      ApiConst.problemResolutions,
      data: {'name': name, 'action': action},
    ),
  );

  /// Переименовать вариант и (или) выключить или включить его.
  Future<Either<Failure, void>> updateResolution(
    String id, {
    String? name,
    bool? isActive,
  }) => _call(
    () => _dio.patch<void>(
      ApiConst.problemResolutionById(id),
      data: {'name': ?name, 'is_active': ?isActive},
    ),
  );

  Future<Either<Failure, T>> _call<T>(Future<T> Function() run) async {
    try {
      return Right(await run());
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code == null) return const Left(Failure.network());
      final data = e.response?.data;
      final message = data is Map ? data['error'] as String? : null;
      return Left(Failure.server(code, message));
    } catch (_) {
      return const Left(Failure.unknown());
    }
  }
}
