import 'package:dio/dio.dart';
import 'package:either_dart/either.dart';
import 'package:injectable/injectable.dart';

import '../../../core/constants/api_constants.dart';
import '../../../core/error/dio_failure.dart';
import '../../../core/error/failure.dart';
import '../domain/picking_models.dart';
import '../domain/picking_shipment.dart';

/// Сетевой источник сборки на ТСД (P9-04): список, заказ, взять, отказаться, короб отгрузки,
/// «не хватает». Всё - только со связью: за кем заказ, решает сервер.
@lazySingleton
class PickingApi {
  PickingApi(this._dio);

  final Dio _dio;

  Future<Either<Failure, List<PickingListItem>>> orders() => _call(
    () => _dio.get<Object?>(ApiConst.pickingOrders),
    (data) => (data as List? ?? const [])
        .map((e) => PickingListItem.fromJson(e as Map<String, dynamic>))
        .toList(),
  );

  Future<Either<Failure, PickingOrder>> order(String id) => _call(
    () => _dio.get<Object?>(ApiConst.pickingOrder(id)),
    (data) => PickingOrder.fromJson(data as Map<String, dynamic>),
  );

  Future<Either<Failure, void>> take(String id) =>
      _call(() => _dio.post<Object?>(ApiConst.pickingTake(id)), (_) {});

  Future<Either<Failure, void>> release(String id) =>
      _call(() => _dio.post<Object?>(ApiConst.pickingRelease(id)), (_) {});

  /// Номер короба «короб N» - от сервера; повтор с тем же ярлыком отдаёт тот же номер.
  Future<Either<Failure, PickingBox>> addBox(String id, String loadUnitId) =>
      _call(
        () => _dio.post<Object?>(
          ApiConst.pickingBoxes(id),
          data: {'load_unit_id': loadUnitId},
        ),
        (data) => PickingBox.fromJson(data as Map<String, dynamic>),
      );

  Future<Either<Failure, ShortageResult>> shortage(
    String id,
    String lineId, {
    required bool shortage,
  }) => _call(
    () => _dio.post<Object?>(
      ApiConst.pickingShortage(id, lineId),
      data: {'shortage': shortage},
    ),
    (data) {
      final map = data as Map<String, dynamic>;
      return (
        stocktakeNumber: (map['stocktake_number'] as num?)?.toInt(),
        created: map['stocktake_created'] as bool? ?? false,
      );
    },
  );

  /// «Завершить сборку» (P9-07): заказ с коробами «N из M».
  Future<Either<Failure, PickingShipment>> complete(String id) =>
      _call(() => _dio.post<Object?>(ApiConst.pickingComplete(id)), _shipment);

  Future<Either<Failure, PickingShipment>> shipment(String id) =>
      _call(() => _dio.get<Object?>(ApiConst.pickingShipment(id)), _shipment);

  /// Отметить печать ярлыков [boxIds]; уже печатавшийся - только с правом повтора (403).
  Future<Either<Failure, PickingShipment>> labels(
    String id,
    List<String> boxIds,
  ) => _call(
    () => _dio.post<Object?>(
      ApiConst.pickingLabels(id),
      data: {'box_ids': boxIds},
    ),
    _shipment,
  );

  /// «Отгрузить»: [boxIds] - все короба заказа.
  Future<Either<Failure, PickingShipment>> ship(
    String id,
    List<String> boxIds,
  ) => _call(
    () =>
        _dio.post<Object?>(ApiConst.pickingShip(id), data: {'box_ids': boxIds}),
    _shipment,
  );

  static PickingShipment _shipment(Object? data) =>
      PickingShipment.fromJson(data as Map<String, dynamic>);

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
