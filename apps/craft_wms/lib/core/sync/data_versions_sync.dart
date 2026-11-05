import 'dart:async';

import 'package:injectable/injectable.dart';

import '../../features/contents/domain/contents_repository.dart';
import '../../features/tasks/domain/tasks_snapshot_sync.dart';
import 'catalog_sync_service.dart';
import 'data_versions.dart';

/// Обновление кэшей ТСД по версиям данных сервера (ADHOC-60, ADR-0018).
///
/// Что: изменилась область на сервере — перечитать её кэш на терминале: справочники, снимок
///      склада, снимок текущих заданий.
/// Зачем: справочник, остатки и задания на ТСД свежеют при ближайшем обращении к серверу, а не
///        только при входе и по «Обновить» — и без фонового опроса.
/// Как: подписка на [DataVersions] между входом и выходом. Справочники перечитываются целиком
///      (так их грузит [CatalogSyncService]); снимок склада и задания — через их отложенное
///      обновление, которое сводит с поводом от подтверждённых операций в одну загрузку.
///      Экраны, открытые в этот момент, перечитывают себя сами (`DataVersionsListener`).
@lazySingleton
class DataVersionsSync {
  DataVersionsSync(this._versions, this._catalog, this._contents, this._tasks);

  final DataVersions _versions;
  final CatalogSyncService _catalog;
  final ContentsSnapshotSync _contents;
  final TasksSnapshotSync _tasks;

  /// Области справочников терминала.
  static const catalogDomains = {
    DataDomain.goods,
    DataDomain.cells,
    DataDomain.settings,
  };

  StreamSubscription<Set<String>>? _sub;

  /// Начать следить за версиями — после входа.
  void start() {
    _sub ??= _versions.changes.listen(onChanged);
  }

  /// Перестать следить и забыть версии — при выходе.
  void stop() {
    _sub?.cancel();
    _sub = null;
    _versions.reset();
  }

  /// Перечитать кэши изменившихся областей. Справочники заодно перечитывают и снимок склада
  /// (последним шагом), поэтому отдельный повод для снимка тогда не нужен.
  void onChanged(Set<String> changed) {
    if (changed.any(catalogDomains.contains)) {
      if (!_catalog.isRunning) unawaited(_catalog.refresh());
    } else if (changed.contains(DataDomain.contents)) {
      _contents.requestRefresh();
    }
    if (changed.contains(DataDomain.tasks)) _tasks.requestRefresh();
  }
}
