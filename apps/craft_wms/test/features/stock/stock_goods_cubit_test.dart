import 'package:craft_wms/core/error/failure.dart';
import 'package:craft_wms/core/warehouse/internal_warehouses.dart';
import 'package:craft_wms/features/contents/domain/contents_entities.dart';
import 'package:craft_wms/features/contents/domain/stock_entities.dart';
import 'package:craft_wms/features/stock/domain/catalog_models.dart';
import 'package:craft_wms/features/stock/domain/catalog_repository.dart';
import 'package:craft_wms/features/stock/presentation/bloc/goods_list_cubit.dart';
import 'package:craft_wms/features/stock/presentation/bloc/stock_goods_cubit.dart';
import 'package:either_dart/either.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../support/contents_stubs.dart';

class _MockCatalog extends Mock implements CatalogRepository {}

/// Вкладка «Товары» в «Остатках» (ADHOC-33): только товары с остатком, количество в строке,
/// поиск и фильтры - в памяти, склады - множественным выбором.
void main() {
  late _MockCatalog catalog;
  late FakeContentsRepository contents;
  late FakeContentsSnapshotSync snapshot;
  late StockGoodsCubit cubit;

  const defect = 'iwh-defect';
  const warehouses = [
    InternalWarehouse(
      id: 'iwh-main',
      code: 'MAIN',
      name: 'Основной',
      isDefault: true,
    ),
    InternalWarehouse(
      id: defect,
      code: 'DEFECT',
      name: 'Брак',
      isDefault: false,
    ),
  ];

  setUp(() {
    catalog = _MockCatalog();
    contents = FakeContentsRepository()
      ..goods = const [
        GoodStock(
          goodId: 'g1',
          name: 'Кальмар сушёный',
          code: '16121',
          groupId: 'fish',
          supplierId: 's1',
          byWarehouse: {null: 10, defect: 2},
        ),
        GoodStock(
          goodId: 'g2',
          name: 'Арахис',
          code: '15567',
          groupId: 'nuts',
          supplierId: 's2',
          byWarehouse: {null: 4},
          pending: true,
        ),
      ];
    snapshot = FakeContentsSnapshotSync();
    when(() => catalog.listGroups()).thenAnswer(
      (_) async => const Right([
        NomenclatureGroup(id: 'snacks', code: '1', name: 'Снеки'),
        NomenclatureGroup(
          id: 'fish',
          code: '2',
          name: 'Рыба',
          parentId: 'snacks',
        ),
        NomenclatureGroup(id: 'nuts', code: '3', name: 'Орехи'),
      ]),
    );
    when(
      () => catalog.listSuppliers(),
    ).thenAnswer((_) async => const Right([]));
    // Справочник терминала знает только «Кальмар» - «Арахис» заведён после загрузки.
    when(() => catalog.goodsByIds(any())).thenAnswer(
      (_) async => {
        'g1': const Good(
          id: 'g1',
          code: '16121',
          name: 'Кальмар сушёный',
          fullName: 'Кальмар сушёный, 100 г',
          uom: 'шт',
          groupId: 'fish',
          supplierId: 's1',
          supplierName: 'ООО «Море»',
          czMarked: true,
        ),
      },
    );
    cubit = StockGoodsCubit(
      catalog,
      contents,
      snapshot,
      FakeInternalWarehouses(warehouses),
    );
  });

  tearDown(() => cubit.close());

  Map<String, double> shown() => {
    for (final g in cubit.state.goods) g.id: cubit.state.stockQty[g.id]!,
  };

  test('открытие: снимок обновлён, все товары с общим количеством', () async {
    await cubit.init();

    expect(snapshot.refreshes, 1);
    expect(cubit.state.status, GoodsListStatus.loaded);
    expect(shown(), {'g1': 12.0, 'g2': 4.0});
    expect(cubit.state.total, 2);
    expect(cubit.state.hasMore, isFalse);
    expect(cubit.state.pendingGoods, {'g2'});
    expect(cubit.state.warehouses, warehouses);
  });

  test(
    'товар для карточки - из справочника целиком, с признаком «маркируемый» (ADHOC-59)',
    () async {
      await cubit.init();

      final squid = cubit.state.goods.firstWhere((g) => g.id == 'g1');
      expect(squid.czMarked, isTrue);
      expect(squid.fullName, 'Кальмар сушёный, 100 г');
      expect(squid.supplierName, 'ООО «Море»');
      // Нет в справочнике - товар из строки снимка, карточка всё равно откроется.
      final peanut = cubit.state.goods.firstWhere((g) => g.id == 'g2');
      expect(peanut.name, 'Арахис');
      expect(peanut.czMarked, isFalse);
    },
  );

  test(
    'без связи - список из прежнего снимка, исход передан репозиторию',
    () async {
      snapshot.result = const Left(Failure.network());
      contents.unitsFreshness = FromSnapshot(DateTime(2026, 10, 21, 9));

      await cubit.init();

      expect(contents.lastRefreshFailure, isA<NetworkFailure>());
      expect(cubit.state.freshness, isA<FromSnapshot>());
      expect(shown(), {'g1': 12.0, 'g2': 4.0});
    },
  );

  test(
    'склады: выбранные суммируются, товара без остатка на них нет',
    () async {
      await cubit.init();

      await cubit.toggleWarehouse(defect);
      expect(shown(), {'g1': 2.0});

      await cubit.toggleWarehouse(null); // + «Основной»
      expect(shown(), {'g1': 12.0, 'g2': 4.0});

      await cubit.toggleWarehouse(defect);
      expect(shown(), {'g1': 10.0, 'g2': 4.0});

      await cubit.allWarehouses();
      expect(cubit.state.warehouseIds, isEmpty);
      expect(shown(), {'g1': 12.0, 'g2': 4.0});
    },
  );

  test('поиск - все слова, без учёта регистра и «ё»; по коду тоже', () async {
    await cubit.init();

    await cubit.setQuery('СУШЕНЫЙ кальмар');
    expect(shown().keys, ['g1']);

    await cubit.setQuery('15567');
    expect(shown().keys, ['g2']);
  });

  test('группа - с вложенными; поставщик; сброс снимает и склады', () async {
    await cubit.init();

    await cubit.setGroup('snacks');
    expect(shown().keys, ['g1']);

    await cubit.setGroup(null);
    await cubit.setSupplier('s2');
    expect(shown().keys, ['g2']);

    await cubit.toggleWarehouse(defect);
    expect(shown(), isEmpty);

    await cubit.resetFilters();
    expect(cubit.state.warehouseIds, isEmpty);
    expect(shown().keys, ['g1', 'g2']);
  });

  test('«потянуть вниз» обновляет снимок заново', () async {
    await cubit.init();
    await cubit.refresh();
    expect(snapshot.refreshes, 2);
  });

  test(
    'снимок обновился в фоне по версиям данных - список перечитан без загрузки (ADHOC-60)',
    () async {
      await cubit.init();
      contents.goods = [contents.goods.first];

      snapshot.emitUpdated();
      await pumpEventQueue();

      expect(snapshot.refreshes, 1);
      expect(shown(), {'g1': 12.0});
    },
  );
}
