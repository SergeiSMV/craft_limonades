import 'package:either_dart/either.dart';
import 'package:flutter/foundation.dart';
import 'package:injectable/injectable.dart';
import 'package:talker_flutter/talker_flutter.dart';

import '../../features/stock/data/catalog_api.dart';
import '../../features/stock/data/catalog_cache.dart';
import '../error/failure.dart';

/// Чем закончилась попытка обновить справочники (ADHOC-10).
///
/// Отдельный тип, а не «успех либо ошибка»: отказ «уже идёт» — это не успех и не сбой, и
/// сваливать его в `Right` значило врать вызывающему. Экран показывал «Справочники обновлены»
/// на нажатие, которое ничего не сделало.
enum SyncOutcome {
  /// Справочники перечитаны с сервера.
  refreshed,

  /// Обновление уже шло — второй запуск не начат.
  alreadyRunning,
}

/// Наполнение локального кэша справочников (P2-02).
///
/// Что: тянет справочники с сервера целиком и укладывает в кэш.
/// Зачем: без этого офлайн-чтение не с чего начинать, а держать логику загрузки в репозитории
///        значило бы смешать «откуда читаем» с «когда обновляем».
/// Как: справочники грузятся по очереди и укладываются по мере готовности — каждый в своей
///      транзакции. Поэтому обрыв связи посередине оставляет уже загруженные справочники
///      в кэше, а не откатывает всё: половина свежего справочника лучше, чем ничего.
@lazySingleton
class CatalogSyncService {
  CatalogSyncService(this._api, this._cache, this._talker);

  final CatalogApi _api;
  final CatalogCache _cache;
  final Talker _talker;

  /// Идёт синхронизация. Защищает от параллельных запусков: вход и ручное обновление могут
  /// совпасть, а второй проход только удвоил бы трафик.
  ///
  /// Наблюдаемое значение, а не просто флаг (ADHOC-10): по нему экран рисует индикатор
  /// обновления. `ValueListenable` несёт текущее состояние, поэтому экран, собранный посреди
  /// обновления, покажет индикатор сразу, а не дождётся следующего события. Это не теория:
  /// синхронизация запускается сразу после входа, то есть ровно тогда, когда главное меню
  /// только появляется.
  final ValueNotifier<bool> _running = ValueNotifier(false);

  /// Идёт ли синхронизация — для индикатора на экране.
  ValueListenable<bool> get running => _running;

  /// Идёт ли синхронизация прямо сейчас.
  bool get isRunning => _running.value;

  /// Загрузить все справочники в кэш.
  ///
  /// Возвращает первую же неудачу: если сеть отвалилась, продолжать смысла нет, а то, что
  /// успело загрузиться, уже лежит в кэше и будет использовано.
  Future<Either<Failure, SyncOutcome>> refresh() async {
    // Отказ «уже идёт» отличается от успеха (ADHOC-10). Раньше он возвращался как `Right`,
    // и экран рапортовал «справочники обновлены», хотя не сделал ничего: `refresh` для
    // вызывающего был неотличим от настоящего обновления.
    if (_running.value) return const Right(SyncOutcome.alreadyRunning);
    _running.value = true;
    final started = DateTime.now();
    try {
      final goods = await _api.listAllGoods();
      if (goods.isLeft) return Left(goods.left);
      await _cache.putGoods(goods.right);

      final groups = await _api.listGroups();
      if (groups.isLeft) return Left(groups.left);
      await _cache.putGroups(groups.right);

      final suppliers = await _api.listSuppliers();
      if (suppliers.isLeft) return Left(suppliers.left);
      await _cache.putSuppliers(suppliers.right);

      final cells = await _api.listAllCells();
      if (cells.isLeft) return Left(cells.left);
      await _cache.putCells(cells.right);

      final barcodes = await _api.listAllBarcodes();
      if (barcodes.isLeft) return Left(barcodes.left);
      await _cache.putBarcodes(
        barcodes.right
            .map(
              (b) => (
                barcode: b.barcode,
                goodId: b.goodId,
                symbology: b.symbology,
              ),
            )
            .toList(),
      );

      _talker.info(
        'Справочники синхронизированы за ${DateTime.now().difference(started).inMilliseconds} мс: '
        'товаров ${goods.right.length}, групп ${groups.right.length}, '
        'поставщиков ${suppliers.right.length}, ячеек ${cells.right.length}, '
        'привязок ШК ${barcodes.right.length}',
      );
      return const Right(SyncOutcome.refreshed);
    } finally {
      _running.value = false;
    }
  }
}
