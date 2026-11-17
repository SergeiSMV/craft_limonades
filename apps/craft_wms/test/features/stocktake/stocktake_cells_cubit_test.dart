import 'dart:convert';

import 'package:craft_wms/core/error/failure.dart';
import 'package:craft_wms/features/stocktake/domain/stocktake_models.dart';
import 'package:craft_wms/features/stocktake/domain/stocktake_repository.dart';
import 'package:craft_wms/features/stocktake/presentation/bloc/stocktake_cells_cubit.dart';
import 'package:either_dart/either.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockRepo extends Mock implements StocktakeRepository {}

/// P10-04: ячейки пересчёта на ТСД - скан ячейки на месте, без связи - начатые подсчёты.
void main() {
  late _MockRepo repo;

  StocktakeCell cell(
    String id,
    String address,
    String status, {
    bool mine = false,
  }) => StocktakeCell(
    id: id,
    stocktakeId: 'ST',
    cellId: 'c-$id',
    address: address,
    status: status,
    mine: mine,
  );

  final free = cell('1', 'M1-1-1-1', StocktakeCellStatus.pending);
  final mine = cell('2', 'M1-1-1-2', StocktakeCellStatus.disrupted, mine: true);

  setUp(() {
    repo = _MockRepo();
    when(() => repo.stocktake('ST')).thenAnswer(
      (_) async => Right(
        StocktakeInfo(
          id: 'ST',
          number: 3,
          scopeKind: StocktakeScope.all,
          status: 'in_progress',
          cells: [free, mine],
        ),
      ),
    );
    when(() => repo.cells('ST')).thenAnswer((_) async => Right([free, mine]));
    when(() => repo.drafts('ST')).thenAnswer((_) async => const []);
    when(() => repo.take(any())).thenAnswer((_) async => const Right(null));
    when(
      () => repo.start(any()),
    ).thenAnswer((inv) async => Right(StocktakeCellView(cell: free)));
  });

  test('свои и свободные - отдельно', () async {
    final c = StocktakeCellsCubit(repo, 'ST');
    await c.load();
    expect(c.state.mine, [mine]);
    expect(c.state.free, [free]);
    await c.close();
  });

  test('скан свободной ячейки берёт её и начинает подсчёт', () async {
    final c = StocktakeCellsCubit(repo, 'ST');
    await c.load();
    await c.scanCell('m1-1-1-1');
    verify(() => repo.take('1')).called(1);
    verify(() => repo.start('1')).called(1);
    expect(c.state.started, isNotNull);
    await c.close();
  });

  test('скан своей сбитой ячейки начинает заново, не беря', () async {
    final c = StocktakeCellsCubit(repo, 'ST');
    await c.load();
    await c.scanCell('M1-1-1-2');
    verifyNever(() => repo.take(any()));
    verify(() => repo.start('2')).called(1);
    await c.close();
  });

  test('чужая ячейка - подсказка, без запросов', () async {
    final c = StocktakeCellsCubit(repo, 'ST');
    await c.load();
    await c.scanCell('Z9');
    expect(c.state.notice, isA<CellsNoticeNotHere>());
    verifyNever(() => repo.take(any()));
    await c.close();
  });

  test('без связи - начатые подсчёты на терминале', () async {
    when(
      () => repo.stocktake('ST'),
    ).thenAnswer((_) async => const Left(Failure.network()));
    when(() => repo.drafts('ST')).thenAnswer(
      (_) async => [
        {
          'view': jsonDecode(
            jsonEncode(StocktakeCellView(cell: mine).toJson()),
          ),
          'lines': const [],
          'boxes': const [],
        },
      ],
    );
    final c = StocktakeCellsCubit(repo, 'ST');
    await c.load();
    expect(c.state.status, StocktakeCellsStatus.error);
    expect(c.state.drafts.single.cell.address, 'M1-1-1-2');
    await c.close();
  });
}
