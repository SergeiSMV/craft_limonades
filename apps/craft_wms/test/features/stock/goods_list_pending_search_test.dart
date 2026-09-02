import 'package:craft_wms/features/stock/data/catalog_models.dart';
import 'package:craft_wms/features/stock/data/catalog_repository.dart';
import 'package:craft_wms/features/stock/presentation/bloc/goods_list_cubit.dart';
import 'package:either_dart/either.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:craft_wms/core/error/failure.dart';

class _MockRepo extends Mock implements CatalogRepository {}

/// Отложенный поиск не должен переживать уход с экрана «Остатки».
///
/// Экран списка при переходе в карточку товара не уничтожается — он остаётся жив под ней.
/// Раньше таймер дебаунса лежал в стейте экрана, и обработчики из соседних виджетов до него
/// не дотягивались: запрос уходил уже из-под карточки. При просадке связи ответ приходил
/// ошибкой, список подменялся блоком «Не удалось загрузить», и кладовщик возвращался
/// из карточки на экран ошибки, хотя поиска не касался.
void main() {
  late _MockRepo repo;
  late GoodsListCubit cubit;

  /// Значения `query`, с которыми ходили в API: по ним видно, ушёл ли отложенный запрос.
  final queries = <String?>[];

  Paged<Good> page() => Paged<Good>(
    items: const [Good(id: 'g1', code: '15567', name: 'Арахис', uom: 'шт')],
    total: 1,
    limit: 50,
    offset: 0,
  );

  setUp(() {
    queries.clear();
    repo = _MockRepo();
    when(
      () => repo.listGroups(),
    ).thenAnswer((_) async => const Right(<NomenclatureGroup>[]));
    when(
      () => repo.listSuppliers(),
    ).thenAnswer((_) async => const Right(<Supplier>[]));
    when(
      () => repo.listGoods(
        query: any(named: 'query'),
        groupId: any(named: 'groupId'),
        supplierId: any(named: 'supplierId'),
        limit: any(named: 'limit'),
        offset: any(named: 'offset'),
      ),
    ).thenAnswer((inv) async {
      queries.add(inv.namedArguments[#query] as String?);
      return Right(page());
    });
    cubit = GoodsListCubit(repo);
  });

  tearDown(() => cubit.close());

  test('отменённый отложенный поиск не уходит в API', () async {
    await cubit.init();
    queries.clear();

    cubit.setQueryDebounced('арахис');
    cubit.cancelPendingSearch(); // уход с экрана: карточка товара, «Ввод остатков», назад

    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(queries, isEmpty, reason: 'запрос не должен уйти из-под открытого поверх экрана');
    expect(cubit.state.query, isNull, reason: 'применённый запрос не менялся');
  });

  test('без отмены отложенный поиск доходит до API', () async {
    await cubit.init();
    queries.clear();

    cubit.setQueryDebounced('арахис');
    await Future<void>.delayed(const Duration(milliseconds: 500));

    expect(queries, ['арахис'], reason: 'обычный сценарий поиска не сломан');
  });

  test('последний ввод побеждает: промежуточные запросы не уходят', () async {
    await cubit.init();
    queries.clear();

    cubit.setQueryDebounced('ара');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    cubit.setQueryDebounced('арахис');
    await Future<void>.delayed(const Duration(milliseconds: 500));

    expect(queries, ['арахис'], reason: 'промежуточный ввод перебит следующим');
  });

  test('setQuery гасит отложенный поиск: старый текст не применится следом', () async {
    await cubit.init();
    queries.clear();

    cubit.setQueryDebounced('арахис');
    await cubit.setQuery(''); // очистка крестиком, пока таймер ещё тикает
    await Future<void>.delayed(const Duration(milliseconds: 500));

    expect(queries, [null], reason: 'ушла только очистка, отложенный текст не применился');
    expect(cubit.state.query, isNull);
  });

  test('ошибка отменённого запроса не подменяет список', () async {
    await cubit.init();
    // Дальше сеть падает — как при просадке связи на складе.
    when(
      () => repo.listGoods(
        query: any(named: 'query'),
        groupId: any(named: 'groupId'),
        supplierId: any(named: 'supplierId'),
        limit: any(named: 'limit'),
        offset: any(named: 'offset'),
      ),
    ).thenAnswer((_) async => const Left(Failure.network()));

    cubit.setQueryDebounced('арахис');
    cubit.cancelPendingSearch();
    await Future<void>.delayed(const Duration(milliseconds: 500));

    expect(
      cubit.state.status,
      GoodsListStatus.loaded,
      reason: 'возврат из карточки не должен приводить на экран ошибки',
    );
    expect(cubit.state.goods, isNotEmpty, reason: 'список остался тем же, что и был');
  });

  test('close() гасит таймер: запрос не уходит после закрытия cubit', () async {
    await cubit.init();
    queries.clear();

    cubit.setQueryDebounced('арахис');
    await cubit.close();
    await Future<void>.delayed(const Duration(milliseconds: 500));

    expect(queries, isEmpty);
  });
}
