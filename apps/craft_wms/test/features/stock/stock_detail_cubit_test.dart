import 'package:craft_wms/core/error/failure.dart';
import 'package:craft_wms/features/contents/domain/contents_entities.dart';
import 'package:craft_wms/features/contents/domain/stock_entities.dart';
import 'package:craft_wms/features/stock/data/catalog_models.dart';
import 'package:craft_wms/features/stock/data/catalog_repository.dart';
import 'package:craft_wms/features/stock/presentation/bloc/stock_detail_cubit.dart';
import 'package:either_dart/either.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../support/contents_stubs.dart';

class _MockRepo extends Mock implements CatalogRepository {}

/// Карточка остатков товара: места - из снимка склада (ADHOC-33), ШК - из справочника.
void main() {
  late _MockRepo repo;
  late FakeContentsRepository contents;
  late FakeContentsSnapshotSync snapshot;
  late StockDetailCubit cubit;

  List<StockPlace> places(List<double> qtys) => [
    for (final q in qtys)
      StockPlace(
        goodId: 'g1',
        cellId: 'c',
        cellAddress: 'M1-1-1-1',
        productionDate: '15-01-2026',
        qty: q,
      ),
  ];

  setUp(() {
    repo = _MockRepo();
    contents = FakeContentsRepository();
    snapshot = FakeContentsSnapshotSync();
    cubit = StockDetailCubit(repo, contents, snapshot);
  });

  test(
    'load: обновляет снимок, тянет места И ШК товара; итог считается',
    () async {
      contents.places = places([10.5, 3, 0.1, 0.2]);
      when(() => repo.listGoodBarcodes('g1')).thenAnswer(
        (_) async =>
            const Right([Barcode(barcode: '460'), Barcode(barcode: 'BOX')]),
      );

      await cubit.load('g1');

      expect(snapshot.refreshes, 1);
      expect(contents.lastRefreshFailure, isNull);
      expect(cubit.state.status, StockDetailStatus.loaded);
      expect(cubit.state.items.length, 4);
      // До тысячных: 0.1 + 0.2 в double не дают «13.800000000000001».
      expect(cubit.state.totalQty, '13.8');
      expect(cubit.state.barcodes.map((b) => b.barcode), ['460', 'BOX']);
    },
  );

  test('без связи - места из прежнего снимка, карточка не уходит в ошибку '
      '(долг 22)', () async {
    snapshot.result = const Left(Failure.network());
    contents.places = places([5]);
    contents.unitsFreshness = FromSnapshot(DateTime(2026, 10, 21, 9));
    when(
      () => repo.listGoodBarcodes('g1'),
    ).thenAnswer((_) async => const Right([]));

    await cubit.load('g1');

    expect(contents.lastRefreshFailure, isA<NetworkFailure>());
    expect(cubit.state.status, StockDetailStatus.loaded);
    expect(cubit.state.totalQty, '5');
    expect(cubit.state.freshness, isA<FromSnapshot>());
  });

  test('ошибка загрузки ШК не валит карточку (остаток важнее)', () async {
    contents.places = places([5]);
    when(
      () => repo.listGoodBarcodes('g1'),
    ).thenAnswer((_) async => const Left(Failure.network()));

    await cubit.load('g1');

    expect(cubit.state.status, StockDetailStatus.loaded);
    expect(cubit.state.barcodes, isEmpty);
  });

  test('unbindBarcode: DELETE → перезагрузка карточки (ШК убыл)', () async {
    // 1-я загрузка - два ШК; после отвязки - один.
    var call = 0;
    contents.places = places([5]);
    when(() => repo.listGoodBarcodes('g1')).thenAnswer((_) async {
      call++;
      return Right(
        call == 1
            ? const [Barcode(barcode: '460'), Barcode(barcode: 'BOX')]
            : const [Barcode(barcode: 'BOX')],
      );
    });
    when(
      () => repo.unbindBarcode(
        goodId: any(named: 'goodId'),
        barcode: '460',
      ),
    ).thenAnswer((_) async => const Right(null));

    await cubit.load('g1');
    expect(cubit.state.barcodes.length, 2);

    await cubit.unbindBarcode('460');

    verify(
      () => repo.unbindBarcode(
        goodId: any(named: 'goodId'),
        barcode: '460',
      ),
    ).called(1);
    expect(cubit.state.barcodes.map((b) => b.barcode), ['BOX']);
  });

  test('unbindBarcode: ошибка DELETE → failure в state', () async {
    contents.places = places([5]);
    when(
      () => repo.listGoodBarcodes('g1'),
    ).thenAnswer((_) async => const Right([Barcode(barcode: '460')]));
    when(
      () => repo.unbindBarcode(
        goodId: any(named: 'goodId'),
        barcode: '460',
      ),
    ).thenAnswer((_) async => const Left(Failure.network()));

    await cubit.load('g1');
    await cubit.unbindBarcode('460');

    expect(cubit.state.failure, isA<NetworkFailure>());
    expect(cubit.state.barcodes.length, 1);
  });
}
