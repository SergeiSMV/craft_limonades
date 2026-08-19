import 'package:craft_wms/core/error/failure.dart';
import 'package:craft_wms/features/stock/data/catalog_models.dart';
import 'package:craft_wms/features/stock/data/catalog_repository.dart';
import 'package:craft_wms/features/stock/presentation/bloc/goods_list_cubit.dart';
import 'package:either_dart/either.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockRepo extends Mock implements CatalogRepository {}

void main() {
  late _MockRepo repo;
  late GoodsListCubit cubit;

  Good good(String id) => Good(id: id, name: 'Товар $id', uom: 'шт');

  Paged<Good> page(List<String> ids, {required int total}) =>
      Paged(items: ids.map(good).toList(), total: total, limit: 50, offset: 0);

  setUp(() {
    repo = _MockRepo();
    cubit = GoodsListCubit(repo);
    // Справочники фильтров — пустые (не предмет теста).
    when(() => repo.listGroups()).thenAnswer((_) async => const Right([]));
    when(() => repo.listSuppliers()).thenAnswer((_) async => const Right([]));
  });

  test('init грузит первую страницу; hasMore=true при total > загруженного', () async {
    when(() => repo.listGoods(
          query: any(named: 'query'),
          groupId: any(named: 'groupId'),
          supplierId: any(named: 'supplierId'),
          offset: any(named: 'offset'),
        )).thenAnswer((_) async => Right(page(['a', 'b'], total: 5)));

    await cubit.init();

    expect(cubit.state.status, GoodsListStatus.loaded);
    expect(cubit.state.goods.length, 2);
    expect(cubit.state.total, 5);
    expect(cubit.state.hasMore, isTrue);
  });

  test('loadMore дозапрашивает от offset=goods.length и дописывает в конец', () async {
    // Первая страница.
    when(() => repo.listGoods(
          query: any(named: 'query'),
          groupId: any(named: 'groupId'),
          supplierId: any(named: 'supplierId'),
          offset: 0,
        )).thenAnswer((_) async => Right(page(['a', 'b'], total: 4)));
    // Вторая страница (offset=2).
    when(() => repo.listGoods(
          query: any(named: 'query'),
          groupId: any(named: 'groupId'),
          supplierId: any(named: 'supplierId'),
          offset: 2,
        )).thenAnswer((_) async => Right(page(['c', 'd'], total: 4)));

    await cubit.init();
    await cubit.loadMore();

    expect(cubit.state.goods.map((g) => g.id).toList(), ['a', 'b', 'c', 'd']);
    expect(cubit.state.hasMore, isFalse); // 4 из 4 — больше не тянем
    verify(() => repo.listGoods(
          query: any(named: 'query'),
          groupId: any(named: 'groupId'),
          supplierId: any(named: 'supplierId'),
          offset: 2,
        )).called(1);
  });

  test('loadMore ничего не делает, когда всё загружено (hasMore=false)', () async {
    when(() => repo.listGoods(
          query: any(named: 'query'),
          groupId: any(named: 'groupId'),
          supplierId: any(named: 'supplierId'),
          offset: any(named: 'offset'),
        )).thenAnswer((_) async => Right(page(['a', 'b'], total: 2)));

    await cubit.init();
    expect(cubit.state.hasMore, isFalse);
    await cubit.loadMore();

    // Только первичный запрос (offset=0) из init — второго не было.
    verify(() => repo.listGoods(
          query: any(named: 'query'),
          groupId: any(named: 'groupId'),
          supplierId: any(named: 'supplierId'),
          offset: 0,
        )).called(1);
    verifyNever(() => repo.listGoods(
          query: any(named: 'query'),
          groupId: any(named: 'groupId'),
          supplierId: any(named: 'supplierId'),
          offset: 2,
        ));
  });

  test('ошибка loadMore не роняет список в error, снимает флаг', () async {
    when(() => repo.listGoods(
          query: any(named: 'query'),
          groupId: any(named: 'groupId'),
          supplierId: any(named: 'supplierId'),
          offset: 0,
        )).thenAnswer((_) async => Right(page(['a', 'b'], total: 4)));
    when(() => repo.listGoods(
          query: any(named: 'query'),
          groupId: any(named: 'groupId'),
          supplierId: any(named: 'supplierId'),
          offset: 2,
        )).thenAnswer((_) async => const Left(Failure.network()));

    await cubit.init();
    await cubit.loadMore();

    expect(cubit.state.status, GoodsListStatus.loaded); // список остался
    expect(cubit.state.goods.length, 2);
    expect(cubit.state.loadingMore, isFalse);
  });
}
