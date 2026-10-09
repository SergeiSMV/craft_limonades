import 'package:injectable/injectable.dart';

import '../../features/contents/domain/contents_repository.dart';
import '../../features/stock/data/catalog_cache.dart';
import '../../features/tasks/domain/tasks_snapshot_sync.dart';
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
  OutboxEffects(this._cache, this._contents, this._tasks);

  final CatalogCache _cache;

  /// Снимок содержимого склада: подтверждённая приёмка или размещение его устаревают (P5-05).
  final ContentsSnapshotSync _contents;

  /// Снимок текущих заданий: приёмка рождает задание, размещение меняет его остаток (ADHOC-24).
  final TasksSnapshotSync _tasks;

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
      case OutboxKind.receiptSubmit:
      case OutboxKind.putawaySubmit:
        break; // приёмка и размещение справочник не меняют — следствий в кэше у них нет
      case OutboxKind.unbindBarcode:
        // Отвязка убирает запись сразу: кладовщик отвязал ошибочный код и не должен видеть
        // его в списке до появления связи. Вернуть её при отказе позволяет `good_id`,
        // который кладётся в тело операции именно ради этого.
        await _cache.removeBarcode(barcode);
    }
  }

  /// Сервер подтвердил операцию: снимаем пометку ожидания.
  Future<void> confirm(OutboxOperation operation) async {
    // Приёмка и размещение двигают короба и россыпь — снимок на терминале устарел. Наложение
    // очереди при чтении эту операцию больше не учитывает (она «отправлена»), поэтому без
    // свежего снимка без связи короб оказался бы там, где лежал до неё. Задания — по той же
    // причине: новое задание от приёмки сервер создаёт только при её проведении.
    if (operation.kind == OutboxKind.receiptSubmit ||
        operation.kind == OutboxKind.putawaySubmit) {
      _contents.requestRefresh();
      _tasks.requestRefresh();
      return;
    }
    final barcode = operation.payload['barcode'] as String?;
    if (barcode == null) return;
    switch (operation.kind) {
      case OutboxKind.bindBarcode:
        await _cache.confirmBarcode(barcode);
      case OutboxKind.unbindBarcode:
        break; // записи уже нет — подтверждать нечего
      case OutboxKind.receiptSubmit:
      case OutboxKind.putawaySubmit:
        break; // приёмка и размещение в кэше справочников следа не оставляют
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
      case OutboxKind.receiptSubmit:
      case OutboxKind.putawaySubmit:
        break; // откатывать в кэше нечего: документ возвращается человеку на разбор
      case OutboxKind.unbindBarcode:
        // Операция старого формата, без товара в теле, — восстанавливать нечем.
        final goodId = operation.payload['good_id'] as String?;
        if (goodId == null) return;
        await _cache.addBarcode(barcode: barcode, goodId: goodId);
    }
  }
}
