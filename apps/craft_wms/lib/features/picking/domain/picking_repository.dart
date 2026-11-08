import 'package:either_dart/either.dart';

import '../../../core/error/failure.dart';
import 'picking_models.dart';
import 'picking_shipment.dart';
import 'picking_view.dart';

/// Что взять в короб отгрузки: строка, источник, партия, количество, марки.
///
/// Источник - ровно один: россыпь ячейки [sourceCellId] или короб хранения [sourceLoadUnitId].
/// [internalWarehouseId] - склад россыпи, как ждёт сервер (пусто - «Основной»).
class PickRequest {
  const PickRequest({
    required this.orderId,
    required this.lineId,
    this.sourceCellId,
    this.sourceLoadUnitId,
    required this.cellAddress,
    this.internalWarehouseId = '',
    required this.productionDate,
    required this.qty,
    this.marks = const [],
  });

  final String orderId;
  final String lineId;
  final String? sourceCellId;
  final String? sourceLoadUnitId;

  /// Ячейка источника - для показа.
  final String cellAddress;
  final String internalWarehouseId;

  /// Дата партии, DD-MM-YYYY.
  final String productionDate;
  final double qty;
  final List<String> marks;
}

/// Сборка на ТСД (P9-06).
///
/// Список, взять, отказаться, короб отгрузки и «не хватает» - только со связью: за кем заказ и
/// номер короба решает сервер. Открытый заказ живёт слепком на терминале, а пик и возврат пика
/// уходят операциями очереди `picking_pick` / `picking_unpick` и работают без связи.
abstract interface class PickingRepository {
  /// Список «СБОРКА»: несобранные заказы, чужие - занятыми.
  Future<Either<Failure, List<PickingListItem>>> orders();

  /// Свои заказы со слепком на терминале - продолжить без связи.
  Future<List<PickingOrderView>> onTerminal();

  /// Заказ с сервера; без связи - слепок терминала ([PickingOrderView.fromCache]). `Left` -
  /// не удалось и слепка нет, либо сервер отказал (удалён в 1С, собран).
  Future<Either<Failure, PickingOrderView>> order(String id);

  /// Заказ из слепка терминала, без сети: после своего пика или возврата.
  Future<PickingOrderView?> cached(String id);

  /// Взять заказ в работу.
  Future<Either<Failure, void>> take(String id);

  /// Отказаться от заказа: собранное остаётся в коробах.
  Future<Either<Failure, void>> release(String id);

  /// Завести короб отгрузки: ярлык (UUID) - терминала, номер - сервера. Новый короб
  /// становится текущим.
  Future<Either<Failure, PickingBox>> addBox(String orderId);

  /// Выбрать короб отгрузки, в который идёт пик.
  Future<void> selectBox(String orderId, String boxId);

  /// Пик операцией очереди. `Right` - сервер принял; `Left(RejectedFailure)` - отказ по
  /// существу, пик снят; другой `Left` - связи нет, пик в очереди и уйдёт сам.
  Future<Either<Failure, void>> pick(PickRequest request);

  /// Вернуть пик. Свой, ещё не ушедший, просто снимается из очереди; иначе - операция
  /// `picking_unpick`. Исходы - как у [pick].
  Future<Either<Failure, void>> unpick(String orderId, PickingPick pick);

  /// Поставить или снять «не хватает» по строке; поставленная заводит пересчёт позиции.
  Future<Either<Failure, ShortageResult>> shortage(
    String orderId,
    String lineId, {
    required bool shortage,
  });

  /// «Завершить сборку» (P9-07) - со связью. Свои пики заказа сначала уходят из очереди;
  /// не ушли - `Left(NetworkFailure)`: сервер ещё не знает всего взятого.
  Future<Either<Failure, PickingShipment>> complete(String orderId);

  /// Собранный заказ с коробами - для ярлыков и отгрузки.
  Future<Either<Failure, PickingShipment>> shipment(String orderId);

  /// Отметить печать ярлыков коробов [boxIds]; ответ - заказ для печати.
  Future<Either<Failure, PickingShipment>> labels(
    String orderId,
    List<String> boxIds,
  );

  /// «Отгрузить»: отсканированы ярлыки всех коробов [boxIds].
  Future<Either<Failure, PickingShipment>> ship(
    String orderId,
    List<String> boxIds,
  );
}
