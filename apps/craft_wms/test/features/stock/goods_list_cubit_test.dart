import 'package:craft_wms/core/error/failure.dart';
import 'package:craft_wms/features/stock/domain/catalog_models.dart';
import 'package:craft_wms/features/stock/domain/catalog_repository.dart';
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
    // Справочники фильтров - пустые (не предмет теста).
    when(() => repo.listGroups()).thenAnswer((_) async => const Right([]));
    when(() => repo.listSuppliers()).thenAnswer((_) async => const Right([]));
  });

  test(
    'init грузит первую страницу; hasMore=true при total > загруженного',
    () async {
      when(
        () => repo.listGoods(
          query: any(named: 'query'),
          groupId: any(named: 'groupId'),
          supplierId: any(named: 'supplierId'),
          offset: any(named: 'offset'),
        ),
      ).thenAnswer((_) async => Right(page(['a', 'b'], total: 5)));

      await cubit.init();

      expect(cubit.state.status, GoodsListStatus.loaded);
      expect(cubit.state.goods.length, 2);
      expect(cubit.state.total, 5);
      expect(cubit.state.hasMore, isTrue);
    },
  );

  test(
    'loadMore дозапрашивает от offset=goods.length и дописывает в конец',
    () async {
      // Первая страница.
      when(
        () => repo.listGoods(
          query: any(named: 'query'),
          groupId: any(named: 'groupId'),
          supplierId: any(named: 'supplierId'),
          offset: 0,
        ),
      ).thenAnswer((_) async => Right(page(['a', 'b'], total: 4)));
      // Вторая страница (offset=2).
      when(
        () => repo.listGoods(
          query: any(named: 'query'),
          groupId: any(named: 'groupId'),
          supplierId: any(named: 'supplierId'),
          offset: 2,
        ),
      ).thenAnswer((_) async => Right(page(['c', 'd'], total: 4)));

      await cubit.init();
      await cubit.loadMore();

      expect(cubit.state.goods.map((g) => g.id).toList(), ['a', 'b', 'c', 'd']);
      expect(cubit.state.hasMore, isFalse); // 4 из 4 - больше не тянем
      verify(
        () => repo.listGoods(
          query: any(named: 'query'),
          groupId: any(named: 'groupId'),
          supplierId: any(named: 'supplierId'),
          offset: 2,
        ),
      ).called(1);
    },
  );

  test(
    'loadMore ничего не делает, когда всё загружено (hasMore=false)',
    () async {
      when(
        () => repo.listGoods(
          query: any(named: 'query'),
          groupId: any(named: 'groupId'),
          supplierId: any(named: 'supplierId'),
          offset: any(named: 'offset'),
        ),
      ).thenAnswer((_) async => Right(page(['a', 'b'], total: 2)));

      await cubit.init();
      expect(cubit.state.hasMore, isFalse);
      await cubit.loadMore();

      // Только первичный запрос (offset=0) из init - второго не было.
      verify(
        () => repo.listGoods(
          query: any(named: 'query'),
          groupId: any(named: 'groupId'),
          supplierId: any(named: 'supplierId'),
          offset: 0,
        ),
      ).called(1);
      verifyNever(
        () => repo.listGoods(
          query: any(named: 'query'),
          groupId: any(named: 'groupId'),
          supplierId: any(named: 'supplierId'),
          offset: 2,
        ),
      );
    },
  );

  test('ошибка loadMore не роняет список в error, снимает флаг', () async {
    when(
      () => repo.listGoods(
        query: any(named: 'query'),
        groupId: any(named: 'groupId'),
        supplierId: any(named: 'supplierId'),
        offset: 0,
      ),
    ).thenAnswer((_) async => Right(page(['a', 'b'], total: 4)));
    when(
      () => repo.listGoods(
        query: any(named: 'query'),
        groupId: any(named: 'groupId'),
        supplierId: any(named: 'supplierId'),
        offset: 2,
      ),
    ).thenAnswer((_) async => const Left(Failure.network()));

    await cubit.init();
    await cubit.loadMore();

    expect(cubit.state.status, GoodsListStatus.loaded); // список остался
    expect(cubit.state.goods.length, 2);
    expect(cubit.state.loadingMore, isFalse);
  });

  group('resolveBarcode (P-FS-16)', () {
    test('привязанный ШК → товар, состояние списка не трогаем', () async {
      when(
        () => repo.resolveGoodByBarcode('4607044662964'),
      ).thenAnswer((_) async => Right(good('g1')));

      final found = await cubit.resolveBarcode('4607044662964');

      expect(found.right?.id, 'g1');
      expect(cubit.state.status, isNot(GoodsListStatus.error));
    });

    test('непривязанный ШК → Right(null): исход штатный, не ошибка', () async {
      when(
        () => repo.resolveGoodByBarcode(any()),
      ).thenAnswer((_) async => const Right(null));

      final res = await cubit.resolveBarcode('0000000000000');

      expect(res.isRight, isTrue);
      expect(res.right, isNull);
      expect(cubit.state.status, isNot(GoodsListStatus.error));
    });

    // ADHOC-06: раньше неудача резолва ставила status: error, и один скан подменял загруженный
    // список экраном «не удалось загрузить». Сам список кладовщик при этом не трогал.
    test('отказ доходит до вызывающего и НЕ роняет список в error', () async {
      when(
        () => repo.resolveGoodByBarcode(any()),
      ).thenAnswer((_) async => const Left(Failure.network()));
      when(
        () => repo.listGoods(
          query: any(named: 'query'),
          groupId: any(named: 'groupId'),
          supplierId: any(named: 'supplierId'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        ),
      ).thenAnswer((_) async => Right(page(['a'], total: 1)));
      await cubit.init();

      final res = await cubit.resolveBarcode('4607044662964');

      expect(res.isLeft, isTrue);
      expect(res.left, isA<NetworkFailure>());
      expect(cubit.state.status, GoodsListStatus.loaded);
      expect(cubit.state.goods, isNotEmpty);
    });
  });

  group('bindBarcode (ADHOC-06)', () {
    test('успех → null, состояние списка не трогаем', () async {
      when(
        () => repo.bindBarcode(
          goodId: any(named: 'goodId'),
          barcode: any(named: 'barcode'),
        ),
      ).thenAnswer((_) async => const Right(null));

      final failure = await cubit.bindBarcode(
        goodId: 'g1',
        barcode: '4607044662964',
      );

      expect(failure, isNull);
      expect(cubit.state.status, isNot(GoodsListStatus.error));
    });

    test('ошибка возвращается вызывающему, а не в state', () async {
      when(
        () => repo.bindBarcode(
          goodId: any(named: 'goodId'),
          barcode: any(named: 'barcode'),
        ),
      ).thenAnswer((_) async => const Left(Failure.server(409)));

      final failure = await cubit.bindBarcode(
        goodId: 'g1',
        barcode: '4607044662964',
      );

      expect(failure, isA<ServerFailure>());
      expect(cubit.state.status, isNot(GoodsListStatus.error));
    });
  });

  test(
    'возврат из карточки подменяет товар свежим из справочника (ADHOC-64)',
    () async {
      when(
        () => repo.listGoods(
          query: any(named: 'query'),
          groupId: any(named: 'groupId'),
          supplierId: any(named: 'supplierId'),
          offset: any(named: 'offset'),
        ),
      ).thenAnswer(
        (_) async => Right(
          Paged(
            items: [good('a').copyWith(czMarked: true), good('b')],
            total: 2,
            limit: 50,
            offset: 0,
          ),
        ),
      );
      // В карточке признак сняли: справочник терминала уже без него.
      when(() => repo.goodById('a')).thenAnswer((_) async => good('a'));

      await cubit.init();
      await cubit.returnedFromCard('a');

      expect(cubit.state.goods.map((g) => g.id).toList(), ['a', 'b']);
      expect(cubit.state.goods.first.czMarked, isFalse);
      // Список заново не запрашивался: прокрутка и подгруженные страницы остаются.
      verify(
        () => repo.listGoods(
          query: any(named: 'query'),
          groupId: any(named: 'groupId'),
          supplierId: any(named: 'supplierId'),
          offset: any(named: 'offset'),
        ),
      ).called(1);
    },
  );

  test(
    'возврат из карточки: товара нет в справочнике - список прежний',
    () async {
      when(
        () => repo.listGoods(
          query: any(named: 'query'),
          groupId: any(named: 'groupId'),
          supplierId: any(named: 'supplierId'),
          offset: any(named: 'offset'),
        ),
      ).thenAnswer((_) async => Right(page(['a'], total: 1)));
      when(() => repo.goodById('a')).thenAnswer((_) async => null);

      await cubit.init();
      final before = cubit.state;
      await cubit.returnedFromCard('a');

      expect(cubit.state, before);
    },
  );
}
