import 'package:craft_wms/core/di/injection.dart';
import 'package:craft_wms/core/gen/strings.g.dart';
import 'package:craft_wms/core/theme/app_theme.dart';
import 'package:craft_wms/features/stock/data/catalog_models.dart';
import 'package:craft_wms/features/stock/data/catalog_repository.dart';
import 'package:craft_wms/features/stock/presentation/bloc/goods_list_cubit.dart';
import 'package:craft_wms/features/stock/presentation/pages/goods_list_page.dart';
import 'package:either_dart/either.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockRepo extends Mock implements CatalogRepository {}

/// Строка поиска на экране «Остатки»: крестик очистки виден только при непустом вводе
/// и по тапу чистит и поле, и запрос.
void main() {
  late _MockRepo repo;

  /// Значения `query`, с которыми экран ходил в API, — по ним видно, что запрос сброшен.
  final queries = <String?>[];

  setUp(() {
    LocaleSettings.useDeviceLocale();
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
      return Right(
        Paged<Good>(
          items: const [
            Good(id: 'g1', code: '15567', name: 'Арахис жареный', uom: 'шт'),
          ],
          total: 1,
          limit: 50,
          offset: 0,
        ),
      );
    });
    if (getIt.isRegistered<GoodsListCubit>()) {
      getIt.unregister<GoodsListCubit>();
    }
    getIt.registerFactory<GoodsListCubit>(() => GoodsListCubit(repo));
  });

  tearDown(() {
    if (getIt.isRegistered<GoodsListCubit>()) {
      getIt.unregister<GoodsListCubit>();
    }
  });

  testWidgets('крестик появляется только при вводе и очищает поиск', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(theme: buildAppTheme(), home: const GoodsListPage()),
    );
    await tester.pumpAndSettle();
    expect(
      find.byIcon(Icons.close),
      findsNothing,
      reason: 'поле пустое — крестика нет',
    );

    await tester.enterText(find.byType(TextField), 'арахис');
    await tester.pump();
    expect(
      find.byIcon(Icons.close),
      findsOneWidget,
      reason: 'есть текст — крестик появился',
    );

    // Дебаунс 350 мс: таймер сам по себе кадров не планирует, двигаем часы явно.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(queries.last, 'арахис');

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    expect(find.text('арахис'), findsNothing, reason: 'строка очищена');
    expect(
      find.byIcon(Icons.close),
      findsNothing,
      reason: 'крестик снова скрыт',
    );
    expect(
      queries.last,
      isNull,
      reason: 'запрос сброшен сразу, без ожидания дебаунса',
    );
  });
}
