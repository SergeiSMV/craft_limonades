import 'package:craft_wms/core/error/failure.dart';
import 'package:craft_wms/features/stock/data/catalog_models.dart';
import 'package:craft_wms/features/stock/data/catalog_repository.dart';
import 'package:craft_wms/features/stock/presentation/bloc/stock_detail_cubit.dart';
import 'package:either_dart/either.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockRepo extends Mock implements CatalogRepository {}

void main() {
  late _MockRepo repo;
  late StockDetailCubit cubit;

  Paged<StockItem> stockPage(List<String> qtys) => Paged(
        items: [
          for (final q in qtys)
            StockItem(
              cellId: 'c',
              cellAddress: 'M1-1-1-1',
              goodId: 'g1',
              batchId: 'b',
              productionDate: '2026-01-15',
              qty: q,
            ),
        ],
        total: qtys.length,
        limit: 200,
        offset: 0,
      );

  setUp(() {
    repo = _MockRepo();
    cubit = StockDetailCubit(repo);
  });

  test('load: тянет остатки И ШК товара; итог считается', () async {
    when(() => repo.listStock(goodId: 'g1'))
        .thenAnswer((_) async => Right(stockPage(['10.5', '3'])));
    when(() => repo.listGoodBarcodes('g1')).thenAnswer(
      (_) async => const Right([Barcode(barcode: '460'), Barcode(barcode: 'BOX')]),
    );

    await cubit.load('g1');

    expect(cubit.state.status, StockDetailStatus.loaded);
    expect(cubit.state.items.length, 2);
    expect(cubit.state.totalQty, '13.5');
    expect(cubit.state.barcodes.map((b) => b.barcode), ['460', 'BOX']);
  });

  test('ошибка загрузки ШК не валит карточку (остаток важнее)', () async {
    when(() => repo.listStock(goodId: 'g1'))
        .thenAnswer((_) async => Right(stockPage(['5'])));
    when(() => repo.listGoodBarcodes('g1'))
        .thenAnswer((_) async => const Left(Failure.network()));

    await cubit.load('g1');

    expect(cubit.state.status, StockDetailStatus.loaded);
    expect(cubit.state.barcodes, isEmpty);
  });

  test('unbindBarcode: DELETE → перезагрузка карточки (ШК убыл)', () async {
    // 1-я загрузка — два ШК; после отвязки — один.
    var call = 0;
    when(() => repo.listStock(goodId: 'g1'))
        .thenAnswer((_) async => Right(stockPage(['5'])));
    when(() => repo.listGoodBarcodes('g1')).thenAnswer((_) async {
      call++;
      return Right(call == 1
          ? const [Barcode(barcode: '460'), Barcode(barcode: 'BOX')]
          : const [Barcode(barcode: 'BOX')]);
    });
    when(() => repo.unbindBarcode('460')).thenAnswer((_) async => const Right(null));

    await cubit.load('g1');
    expect(cubit.state.barcodes.length, 2);

    await cubit.unbindBarcode('460');

    verify(() => repo.unbindBarcode('460')).called(1);
    expect(cubit.state.barcodes.map((b) => b.barcode), ['BOX']); // перезагрузилось без 460
  });

  test('unbindBarcode: ошибка DELETE → failure в state, без перезагрузки', () async {
    when(() => repo.listStock(goodId: 'g1'))
        .thenAnswer((_) async => Right(stockPage(['5'])));
    when(() => repo.listGoodBarcodes('g1'))
        .thenAnswer((_) async => const Right([Barcode(barcode: '460')]));
    when(() => repo.unbindBarcode('460'))
        .thenAnswer((_) async => const Left(Failure.network()));

    await cubit.load('g1');
    await cubit.unbindBarcode('460');

    expect(cubit.state.failure, isA<NetworkFailure>());
    expect(cubit.state.barcodes.length, 1); // не перезагружали — 460 на месте
  });
}
