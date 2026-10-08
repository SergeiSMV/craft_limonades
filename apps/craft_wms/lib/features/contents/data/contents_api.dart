import 'package:dio/dio.dart';
import 'package:either_dart/either.dart';
import 'package:injectable/injectable.dart';

import '../../../core/constants/api_constants.dart';
import '../../../core/error/dio_failure.dart';
import '../../../core/error/failure.dart';
import '../domain/contents_entities.dart';
import 'contents_dto.dart';

/// Сетевой источник содержимого ячеек и коробов (P5-05). Экраны сюда не ходят — между ними
/// и сетью стоит `ContentsRepositoryImpl` со снимком и наложением очереди.
@lazySingleton
class ContentsApi {
  ContentsApi(this._dio);

  final Dio _dio;

  /// Ожидание ответа карточки и ячейки. Короче общего: кладовщик стоит со сканером у ячейки,
  /// и при плохой связи снимок на терминале полезнее, чем ещё десять секунд крутилки.
  static const _viewTimeout = Duration(seconds: 5);

  /// Карточка короба, в том числе неживого.
  Future<Either<Failure, LoadUnitView>> card(String id) => _get(
    ApiConst.loadUnitCard(id),
    (d) => loadUnitFromJson(d as Map<String, dynamic>),
    timeout: _viewTimeout,
  );

  /// Содержимое ячейки.
  Future<Either<Failure, CellView>> cell(String id) => _get(
    ApiConst.cellContents(id),
    (d) => cellFromJson(d as Map<String, dynamic>),
    timeout: _viewTimeout,
  );

  /// Снимок содержимого всего склада — ждём по общему таймауту: это весь склад одним ответом.
  Future<Either<Failure, ContentsSnapshot>> snapshot() => _get(
    ApiConst.contentsSnapshot,
    (d) => ContentsSnapshot.fromJson(d as Map<String, dynamic>),
  );

  Future<Either<Failure, T>> _get<T>(
    String path,
    T Function(Object? data) parse, {
    Duration? timeout,
  }) async {
    try {
      final resp = await _dio.get<Object?>(
        path,
        options: timeout == null ? null : Options(receiveTimeout: timeout),
      );
      return Right(parse(resp.data));
    } on DioException catch (e) {
      return Left(mapDioError(e));
    } catch (_) {
      return const Left(Failure.unknown());
    }
  }
}
