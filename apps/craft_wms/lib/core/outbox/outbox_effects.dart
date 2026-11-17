import 'package:injectable/injectable.dart';

import '../../features/contents/domain/contents_repository.dart';
import '../../features/stock/data/catalog_cache.dart';
import '../../features/tasks/domain/tasks_snapshot_sync.dart';
import 'outbox_operation.dart';

/// Локальные следствия операции очереди (P2-06).
///
/// Что: как операция меняет локальный кэш на каждой стадии - при постановке, при подтверждении
/// сервером и при отказе.
/// Зачем: у записи два пути отправки - немедленный, из репозитория, и отложенный, из движка
///        синхронизации. Пока «что записать локально» знал только репозиторий, отправка
///        движком оставляла кэш нетронутым: привязка уходила на сервер, а в карточке товара
///        штрихкода не появлялось до следующей полной синхронизации справочников. Найдено
///        на устройстве.
/// Как: следствия описаны один раз и применяются обоими путями.
///
/// Оптимистичность здесь не украшение: кладовщик привязывает ШК без связи и должен увидеть
/// результат сразу, иначе решит, что работа пропала, и сделает её заново. Поэтому запись
/// появляется при постановке в очередь - но с пометкой «ожидает», чтобы не выдавать очередь
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
        // ШК из марки ЧЗ - товар маркируемый (CZ-05), как его пометит и сервер.
        if (payload['from_cz_mark'] == true) {
          await _cache.setGoodCzMarked(goodId, true);
        }
      case OutboxKind.receiptSubmit:
      case OutboxKind.putawaySubmit:
      case OutboxKind.movementSubmit:
      case OutboxKind.problemSubmit:
      case OutboxKind.returnSubmit:
      case OutboxKind.stocktakeCellSubmit:
      case OutboxKind.pickingPick:
      case OutboxKind.pickingUnpick:
      case OutboxKind.pickingReturn:
        break; // приёмка, размещение и движение справочник не меняют - следствий в кэше нет
      case OutboxKind.unbindBarcode:
        // Отвязка убирает запись сразу: кладовщик отвязал ошибочный код и не должен видеть
        // его в списке до появления связи. Вернуть её при отказе позволяет `good_id`,
        // который кладётся в тело операции именно ради этого.
        await _cache.removeBarcode(barcode);
    }
  }

  /// Заново наложить неотправленные привязки и отвязки ШК на свежий справочник (ADHOC-36).
  ///
  /// Что: повторяет оптимистичное следствие каждой операции из [unsent] в порядке очереди.
  /// Зачем: загрузка справочников заменяет таблицу привязок целиком, а сервер ещё не знает
  ///        о том, что лежит в очереди. Без наложения неотправленная привязка пропадала из кэша
  ///        (товар по ШК без связи не находился), а отвязанный код возвращался в карточку.
  /// Как: те же следствия, что при постановке в очередь, - правило «что меняет операция»
  ///      по-прежнему описано один раз. Порядок важен: привязка и отвязка одного кода должны
  ///      сойтись в то, чем кончилась последняя.
  Future<void> reapplyBarcodes(List<OutboxOperation> unsent) async {
    for (final op in unsent) {
      if (op.kind != OutboxKind.bindBarcode &&
          op.kind != OutboxKind.unbindBarcode) {
        continue;
      }
      await applyOptimistic(kind: op.kind, payload: op.payload);
    }
  }

  /// Сервер подтвердил операцию: снимаем пометку ожидания.
  Future<void> confirm(OutboxOperation operation) async {
    // Приёмка, размещение и движение двигают короба и россыпь - снимок на терминале устарел. Наложение
    // очереди при чтении эту операцию больше не учитывает (она «отправлена»), поэтому без
    // свежего снимка без связи короб оказался бы там, где лежал до неё. Задания - по той же
    // причине: новое задание от приёмки сервер создаёт только при её проведении.
    // Отгрузка возврата (ADHOC-31) снимает товар со склада и выполняет задание - тоже оба.
    // Подсчёт ячейки пересчёта (P10-04) правит остаток, переносит короба и двигает ход задания.
    // Возврат на место (P9-07-1) двигает остаток и марки и уменьшает задание.
    if (operation.kind == OutboxKind.receiptSubmit ||
        operation.kind == OutboxKind.putawaySubmit ||
        operation.kind == OutboxKind.returnSubmit ||
        operation.kind == OutboxKind.stocktakeCellSubmit ||
        operation.kind == OutboxKind.pickingReturn) {
      _contents.requestRefresh();
      _tasks.requestRefresh();
      return;
    }
    // Движение и пометка брака заданий не касаются - устаревает только содержимое склада
    // (P6-04, P6-07-2).
    // Пик и его возврат (P9-06) меняют «в сборке» у россыпи - то же следствие.
    if (operation.kind == OutboxKind.movementSubmit ||
        operation.kind == OutboxKind.problemSubmit ||
        operation.kind == OutboxKind.pickingPick ||
        operation.kind == OutboxKind.pickingUnpick) {
      _contents.requestRefresh();
      return;
    }
    final barcode = operation.payload['barcode'] as String?;
    if (barcode == null) return;
    switch (operation.kind) {
      case OutboxKind.bindBarcode:
        await _cache.confirmBarcode(barcode);
      case OutboxKind.unbindBarcode:
        break; // записи уже нет - подтверждать нечего
      case OutboxKind.receiptSubmit:
      case OutboxKind.putawaySubmit:
      case OutboxKind.movementSubmit:
      case OutboxKind.problemSubmit:
      case OutboxKind.returnSubmit:
      case OutboxKind.stocktakeCellSubmit:
      case OutboxKind.pickingPick:
      case OutboxKind.pickingUnpick:
      case OutboxKind.pickingReturn:
        break; // приёмка, размещение и движение в кэше справочников следа не оставляют
    }
  }

  /// Сервер отказал по существу: возвращаем локальное состояние к тому, что было.
  ///
  /// Это и есть «локальный откат» из критерия P2-06. Без него отклонённая привязка осталась
  /// бы в карточке навсегда - с пометкой «ожидает», которой уже нечего ждать.
  Future<void> rollback(OutboxOperation operation) async {
    final barcode = operation.payload['barcode'] as String?;
    if (barcode == null) return;
    switch (operation.kind) {
      case OutboxKind.bindBarcode:
        await _cache.removeBarcode(barcode);
      case OutboxKind.receiptSubmit:
      case OutboxKind.putawaySubmit:
      case OutboxKind.movementSubmit:
      case OutboxKind.problemSubmit:
      case OutboxKind.returnSubmit:
      case OutboxKind.stocktakeCellSubmit:
      case OutboxKind.pickingPick:
      case OutboxKind.pickingUnpick:
      case OutboxKind.pickingReturn:
        break; // откатывать в кэше нечего: документ возвращается человеку на разбор
      case OutboxKind.unbindBarcode:
        // Операция старого формата, без товара в теле, - восстанавливать нечем.
        final goodId = operation.payload['good_id'] as String?;
        if (goodId == null) return;
        await _cache.addBarcode(barcode: barcode, goodId: goodId);
    }
  }
}
