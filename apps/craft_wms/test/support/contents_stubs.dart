import 'dart:async';

import 'package:craft_wms/core/error/failure.dart';
import 'package:craft_wms/core/di/injection.dart';
import 'package:craft_wms/core/warehouse/internal_warehouses.dart';
import 'package:craft_wms/features/contents/domain/contents_entities.dart';
import 'package:craft_wms/features/contents/domain/contents_repository.dart';
import 'package:craft_wms/features/contents/domain/load_unit_label_printer.dart';
import 'package:craft_wms/features/contents/domain/stock_entities.dart';
import 'package:craft_wms/features/contents/presentation/bloc/boxes_cubit.dart';
import 'package:craft_wms/features/stock/data/catalog_repository.dart';
import 'package:craft_wms/features/stock/presentation/bloc/stock_goods_cubit.dart';
import 'package:craft_wms/features/tasks/domain/tasks_snapshot_sync.dart';
import 'package:either_dart/either.dart';
import 'package:mocktail/mocktail.dart';

/// Заглушка загрузки снимка содержимого склада (P5-05): ничего не качает, считает просьбы.
///
/// Нужна тестам очереди и синхронизации справочников: им снимок не интересен, но обе службы
/// теперь его дёргают — подтверждение приёмки и размещения, заход «Обновить».
class FakeContentsSnapshotSync implements ContentsSnapshotSync {
  /// Сколько раз загружали сразу.
  int refreshes = 0;

  /// Сколько раз просили загрузить вскоре.
  int requests = 0;

  /// Что вернёт [refresh].
  Either<Failure, void> result = const Right(null);

  @override
  Future<Either<Failure, void>> refresh() async {
    refreshes++;
    return result;
  }

  @override
  void requestRefresh() => requests++;

  final _updated = StreamController<void>.broadcast();

  @override
  Stream<void> get updated => _updated.stream;

  /// Снимок «обновился» (ADHOC-60): открытые экраны перечитывают себя.
  void emitUpdated() => _updated.add(null);
}

/// Заглушка репозитория содержимого (P5-05) для экранов: ячейки ищутся в [cells] по адресу,
/// ответы — то, что положил тест.
class FakeContentsRepository implements ContentsRepository {
  /// Справочник ячеек: адрес → ячейка.
  final Map<String, CellRef> cells = {};

  /// Что вернёт [loadUnit].
  Either<Failure, Viewed<LoadUnitView>> loadUnitResult = const Left(
    Failure.network(),
  );

  /// Что вернёт [cell].
  Either<Failure, Viewed<CellView>> cellResult = const Left(Failure.network());

  @override
  Future<Either<Failure, Viewed<LoadUnitView>>> loadUnit(String id) async =>
      loadUnitResult;

  @override
  Future<Either<Failure, Viewed<CellView>>> cell(CellRef cell) async =>
      cellResult;

  @override
  Future<CellRef?> findCell(String address) async => cells[address];

  /// Ячейки коробов в снимке терминала: id → адрес (ADHOC-63).
  final Map<String, String> cachedCells = {};

  @override
  Future<String?> cachedLoadUnitCell(String id) async => cachedCells[id];

  /// Короба в снимке терминала (ADHOC-70); нет — `null`, и экран спросит [loadUnit].
  final Map<String, LoadUnitView> cachedUnits = {};

  @override
  Future<LoadUnitView?> cachedLoadUnit(String id) async => cachedUnits[id];

  /// Короба ЧЗ: код `00`+SSCC → ГЕ (CZ-06).
  final Map<String, String> czBoxes = {};

  @override
  Future<Either<Failure, String?>> loadUnitIdByCzCode(String czCode) async =>
      Right(czBoxes[czCode]);

  /// Марки склада (CZ-06): ищутся по КИ и по коду упаковки.
  List<StockMark> marks = const [];

  @override
  Future<List<StockMark>> marksByCode(String code) async => [
    for (final m in marks)
      if (m.cis == code || m.aggregateCode == code) m,
  ];

  /// Короба склада для вкладки «Короба» (P5-05-1).
  List<LoadUnitView> units = const [];

  /// Откуда список коробов и выдача поиска.
  DataFreshness unitsFreshness = const FreshFromServer();

  /// Что вернёт [history].
  Either<Failure, LoadUnitHistory> historyResult = const Left(
    Failure.network(),
  );

  /// Коды, по которым искали.
  final List<String> searches = [];

  @override
  Future<Viewed<List<LoadUnitView>>> loadUnits({
    Failure? refreshFailure,
  }) async {
    lastRefreshFailure = refreshFailure;
    return Viewed(units, unitsFreshness);
  }

  /// С каким исходом обновления снимка читали список в последний раз (ADHOC-22).
  Failure? lastRefreshFailure;

  @override
  Future<Either<Failure, Viewed<List<LoadUnitView>>>> searchLoadUnits(
    String code,
  ) async {
    searches.add(code);
    return Right(
      Viewed([
        for (final lu in units)
          if (matchesShortCode(lu.id, code)) lu,
      ], unitsFreshness),
    );
  }

  @override
  Future<Either<Failure, LoadUnitHistory>> history(String id) async =>
      historyResult;

  /// Остатки по товарам и места товаров (ADHOC-33).
  List<GoodStock> goods = const [];
  List<StockPlace> places = const [];

  @override
  Future<Viewed<List<GoodStock>>> goodsStock({Failure? refreshFailure}) async {
    lastRefreshFailure = refreshFailure;
    return Viewed(goods, unitsFreshness);
  }

  @override
  Future<Viewed<List<StockPlace>>> goodPlaces(
    String goodId, {
    Failure? refreshFailure,
  }) async {
    lastRefreshFailure = refreshFailure;
    return Viewed([
      for (final p in places)
        if (p.goodId == goodId) p,
    ], unitsFreshness);
  }
}

/// Заглушка печати ярлыка (P5-05-1): запоминает, что печатали, отвечает [error].
class FakeLabelPrinter implements LoadUnitLabelPrinter {
  final List<String> printed = [];

  /// Текст ошибки печати; `null` — напечатано.
  String? error;

  @override
  Future<String?> printLabel(String loadUnitId) async {
    printed.add(loadUnitId);
    return error;
  }
}

/// Зарегистрировать [repo] как репозиторий содержимого в getIt (вместо прежнего).
FakeContentsRepository registerFakeContentsRepository([
  FakeContentsRepository? repo,
]) {
  final r = repo ?? FakeContentsRepository();
  if (getIt.isRegistered<ContentsRepository>()) {
    getIt.unregister<ContentsRepository>();
  }
  getIt.registerSingleton<ContentsRepository>(r);
  // Вкладку «Короба» в «Остатках» (P5-05-1) страница создаёт всегда — кубиту нужен репозиторий
  // и загрузка снимка.
  if (getIt.isRegistered<BoxesCubit>()) getIt.unregister<BoxesCubit>();
  getIt.registerFactory<BoxesCubit>(
    () => BoxesCubit(r, FakeContentsSnapshotSync()),
  );
  return r;
}

/// Заглушка обновления снимка заданий (ADHOC-24): ничего не качает, считает просьбы.
class FakeTasksSnapshotSync implements TasksSnapshotSync {
  /// Сколько раз просили загрузить вскоре.
  int requests = 0;

  @override
  void requestRefresh() => requests++;
}

/// Справочник внутренних складов без базы и сети: отдаёт [items] (ADHOC-33).
class FakeInternalWarehouses extends Fake implements InternalWarehouses {
  FakeInternalWarehouses([this.items = const []]);

  final List<InternalWarehouse> items;

  @override
  Future<List<InternalWarehouse>> all() async => items;
}

/// Зарегистрировать кубит вкладки «Товары» «Остатков» (ADHOC-33) поверх [catalog] и [contents]:
/// страница «Остатков» создаёт его всегда.
void registerStockGoodsCubit(
  CatalogRepository catalog,
  FakeContentsRepository contents, {
  List<InternalWarehouse> warehouses = const [],
}) {
  if (getIt.isRegistered<StockGoodsCubit>()) {
    getIt.unregister<StockGoodsCubit>();
  }
  getIt.registerFactory<StockGoodsCubit>(
    () => StockGoodsCubit(
      catalog,
      contents,
      FakeContentsSnapshotSync(),
      FakeInternalWarehouses(warehouses),
    ),
  );
}
