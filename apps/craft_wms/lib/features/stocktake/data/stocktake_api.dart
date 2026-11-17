import 'package:dio/dio.dart';
import 'package:either_dart/either.dart';
import 'package:injectable/injectable.dart';

import '../../../core/constants/api_constants.dart';
import '../../../core/error/dio_failure.dart';
import '../../../core/error/failure.dart';
import '../domain/stocktake_models.dart';

/// Сетевой источник пересчёта (P10-03): ход, ячейки, взятие, скан ячейки, заведение и
/// закрытие. Склады в ответе - как на сервере; к соглашению терминала их приводит репозиторий.
@lazySingleton
class StocktakeApi {
  StocktakeApi(this._dio);

  final Dio _dio;

  Future<Either<Failure, StocktakeInfo>> stocktake(String id) => _call(
    () => _dio.get<Object?>(ApiConst.stocktakeById(id)),
    (data) => StocktakeInfo.fromJson(data as Map<String, dynamic>),
  );

  Future<Either<Failure, List<StocktakeCell>>> cells(String stocktakeId) =>
      _call(
        () => _dio.get<Object?>(ApiConst.stocktakeCells(stocktakeId)),
        (data) => ((data as Map<String, dynamic>)['cells'] as List? ?? const [])
            .map((e) => StocktakeCell.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  Future<Either<Failure, void>> take(String cellId) => _call(
    () => _dio.post<Object?>(ApiConst.stocktakeCellTake(cellId)),
    (_) {},
  );

  Future<Either<Failure, void>> release(String cellId) => _call(
    () => _dio.post<Object?>(ApiConst.stocktakeCellRelease(cellId)),
    (_) {},
  );

  /// Ответ - ячейка с позициями плоским объектом: поля ячейки и `positions`.
  Future<Either<Failure, StocktakeCellView>> start(String cellId) => _call(
    () => _dio.post<Object?>(ApiConst.stocktakeCellStart(cellId)),
    (data) {
      final map = data as Map<String, dynamic>;
      return StocktakeCellView(
        cell: StocktakeCell.fromJson(map),
        positions: (map['positions'] as List? ?? const [])
            .map((e) => StocktakePosition.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
    },
  );

  Future<Either<Failure, StocktakeCreated>> create(Map<String, dynamic> body) =>
      _call(() => _dio.post<Object?>(ApiConst.stocktakes, data: body), (data) {
        final map = data as Map<String, dynamic>;
        return (
          id: map['id'] as String,
          number: (map['number'] as num).toInt(),
          cells: (map['cells'] as num).toInt(),
        );
      });

  Future<Either<Failure, void>> close(String id, {required bool force}) =>
      _call(
        () => _dio.post<Object?>(
          ApiConst.stocktakeClose(id),
          data: {'force': force},
        ),
        (_) {},
      );

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
