import 'package:either_dart/either.dart';
import 'package:injectable/injectable.dart';

import '../../features/stock/data/catalog_api.dart';
import '../error/failure.dart';
import 'outbox_operation.dart';

/// Исполнитель операций очереди (P2-04): превращает строку очереди в сетевой вызов.
///
/// Что: по типу операции выбирает запрос и передаёт ему тело из `payload`.
/// Зачем: движок синхронизации не должен знать ни одного маршрута API — иначе добавление
///        нового типа операции правило бы и очередь, и движок, и сеть сразу.
/// Как: `switch` по [OutboxKind]; тип уже разобран репозиторием, поэтому «неизвестного»
///      случая здесь нет — строку с незнакомым типом очередь до отправщика не доводит.
@lazySingleton
class OutboxSender {
  OutboxSender(this._api);

  final CatalogApi _api;

  /// Выполнить операцию. `Right` — сервер принял; `Left` — отказ, а решать, повторять его
  /// или нет, будет движок.
  Future<Either<Failure, void>> send(OutboxOperation operation) {
    return switch (operation.kind) {
      OutboxKind.bindBarcode => _api.bindBarcode(
        goodId: operation.payload['good_id'] as String,
        barcode: operation.payload['barcode'] as String,
      ),
      OutboxKind.unbindBarcode => _api.unbindBarcode(
        operation.payload['barcode'] as String,
      ),
    };
  }
}
