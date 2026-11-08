import 'package:either_dart/either.dart';

import '../../../core/error/failure.dart';
import 'picking_return.dart';

/// Возврат на места по заданию «вернуть на места» (P9-07-1).
///
/// Что вернуть - только со связью: остаток считает сервер по пикам и плану. Сам возврат уходит
/// операцией очереди и работает без связи: из короба отгрузки - `picking_return`, взятое
/// удалённого заказа, ещё не перенесённое, - `picking_unpick` (возврат пика в источник).
abstract interface class PickingReturnRepository {
  /// Что вернуть по заказу [orderId].
  Future<Either<Failure, PickingReturnView>> view(String orderId);

  /// Вернуть [qty] из короба отгрузки пика [pick] в ячейку [cellId]; маркируемый - марками
  /// [marks]. `Right` - сервер принял; `Left(RejectedFailure)` - отказ по существу, операция
  /// снята; другой `Left` - связи нет, возврат в очереди и уйдёт сам.
  Future<Either<Failure, void>> putBack(
    PickingReturnPick pick, {
    required double qty,
    required String cellId,
    List<String> marks = const [],
  });

  /// Вернуть в источник взятое удалённого заказа, ещё не перенесённое. Исходы - как у
  /// [putBack].
  Future<Either<Failure, void>> unpick(PickingReturnPick pick);
}
