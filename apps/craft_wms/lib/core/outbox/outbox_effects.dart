import 'package:injectable/injectable.dart';

import '../../features/stock/data/catalog_cache.dart';
import 'outbox_operation.dart';

/// Локальные следствия операции очереди (P2-06).
///
/// Что: как операция меняет локальный кэш на каждой стадии — при постановке, при подтверждении
/// сервером и при отказе.
/// Зачем: у записи два пути отправки — немедленный, из репозитория, и отложенный, из движка
///        синхронизации. Пока «что записать локально» знал только репозиторий, отправка
///        движком оставляла кэш нетронутым: привязка уходила на сервер, а в карточке товара
///        штрихкода не появлялось до следующей полной синхронизации справочников. Найдено
///        на устройстве.
/// Как: следствия описаны один раз и применяются обоими путями.
///
/// Оптимистичность здесь не украшение: кладовщик привязывает ШК без связи и должен увидеть
/// результат сразу, иначе решит, что работа пропала, и сделает её заново. Поэтому запись
/// появляется при постановке в очередь — но с пометкой «ожидает», чтобы не выдавать очередь
/// за факт справочника, и снимается обратно, если сервер откажет.
@lazySingleton
class OutboxEffects {
  OutboxEffects(this._cache);

  final CatalogCache _cache;

  /// Применить следствие сразу при постановке в очередь.
  Future<void> applyOptimistic({
    required OutboxKind kind,
    required Map<String, dynamic> payload,
  }) async {
    final barcode = payload['barcode'] as String?;
    if (barcode == null) return;
    switch (kind) {
      case OutboxKind.bindBarcode:
        final goodId = payload['good_id'] as String?;
        if (goodId == null) return;
        await _cache.addBarcode(
          barcode: barcode,
          goodId: goodId,
          pending: true,
        );
      case OutboxKind.unbindBarcode:
        // Отвязка убирает запись сразу: кладовщик отвязал ошибочный код и не должен видеть
        // его в списке до появления связи. Вернуть её при отказе позволяет `good_id`,
        // который кладётся в тело операции именно ради этого.
        await _cache.removeBarcode(barcode);
    }
  }

  /// Сервер подтвердил операцию: снимаем пометку ожидания.
  Future<void> confirm(OutboxOperation operation) async {
    final barcode = operation.payload['barcode'] as String?;
    if (barcode == null) return;
    switch (operation.kind) {
      case OutboxKind.bindBarcode:
        await _cache.confirmBarcode(barcode);
      case OutboxKind.unbindBarcode:
        break; // записи уже нет — подтверждать нечего
    }
  }

  /// Сервер отказал по существу: возвращаем локальное состояние к тому, что было.
  ///
  /// Это и есть «локальный откат» из критерия P2-06. Без него отклонённая привязка осталась
  /// бы в карточке навсегда — с пометкой «ожидает», которой уже нечего ждать.
  Future<void> rollback(OutboxOperation operation) async {
    final barcode = operation.payload['barcode'] as String?;
    if (barcode == null) return;
    switch (operation.kind) {
      case OutboxKind.bindBarcode:
        await _cache.removeBarcode(barcode);
      case OutboxKind.unbindBarcode:
        // Операция старого формата, без товара в теле, — восстанавливать нечем.
        final goodId = operation.payload['good_id'] as String?;
        if (goodId == null) return;
        await _cache.addBarcode(barcode: barcode, goodId: goodId);
    }
  }
}
