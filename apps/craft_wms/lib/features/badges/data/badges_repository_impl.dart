import 'package:dio/dio.dart';
import 'package:either_dart/either.dart';
import 'package:injectable/injectable.dart';

import '../../../core/constants/api_constants.dart';
import '../../../core/error/dio_failure.dart';
import '../../../core/error/failure.dart';
import '../domain/badge_holder.dart';
import '../domain/badges_repository.dart';

/// «Бейджи» через API (ADHOC-65): `GET /badges` и `GET /badges/{id}`.
@LazySingleton(as: BadgesRepository)
class BadgesRepositoryImpl implements BadgesRepository {
  BadgesRepositoryImpl(this._dio);

  final Dio _dio;

  @override
  Future<Either<Failure, List<BadgeHolder>>> holders() => _call(
    () => _dio.get<Object?>(ApiConst.badges),
    (data) => (data as List? ?? const [])
        .map((e) => BadgeHolder.fromJson(e as Map<String, dynamic>))
        .toList(),
  );

  @override
  Future<Either<Failure, BadgeNumber>> badge(String userId) =>
      _call(() => _dio.get<Object?>(ApiConst.badge(userId)), (data) {
        final map = data as Map<String, dynamic>;
        return (
          fullName: map['full_name'] as String? ?? '',
          number: map['badge'] as String,
        );
      });

  Future<Either<Failure, T>> _call<T>(
    Future<Response<Object?>> Function() send,
    T Function(Object? data) parse,
  ) async {
    try {
      final resp = await send();
      return Right(parse(resp.data));
    } on DioException catch (e) {
      return Left(mapDioError(e));
    } catch (_) {
      return const Left(Failure.unknown());
    }
  }
}
