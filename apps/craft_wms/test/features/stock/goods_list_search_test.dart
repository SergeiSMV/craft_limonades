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

import '../../support/fake_scanner_service.dart';

import '../../support/contents_stubs.dart';
import '../../support/entry_draft_stub.dart';

class _MockRepo extends Mock implements CatalogRepository {}

/// Строка поиска на экране «Остатки»: крестик очистки виден только при непустом вводе
/// и по тапу чистит и поле, и запрос.
void main() {
  late _MockRepo repo;

  /// Значения `query`, с которыми экран ходил в API, — по ним видно, что запрос сброшен.
  final queries = <String?>[];

  setUp(() {
    registerEmptyDraftStore();
    // Адрес ячейки, которой нет в справочнике, остаётся текстом поиска (P5-05).
    registerFakeContentsRepository();
    LocaleSettings.useDeviceLocale();
    registerFakeScanner(); // экран подписывается на сканер через DI
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
    when(
      () => repo.resolveGoodByBarcode(any()),
    ).thenAnswer((_) async => const Right(null));
    if (getIt.isRegistered<GoodsListCubit>()) {
      getIt.unregister<GoodsListCubit>();
    }
    getIt.registerFactory<GoodsListCubit>(() => GoodsListCubit(repo));
  });

  tearDown(() {
    when(
      () => repo.resolveGoodByBarcode(any()),
    ).thenAnswer((_) async => const Right(null));
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

  testWidgets('скан непривязанного ШК: предложение привязки, поиск не уходит', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(theme: buildAppTheme(), home: const GoodsListPage()),
    );
    await tester.pumpAndSettle();
    queries.clear();

    // Сканер вводит строку целиком и жмёт Enter.
    await tester.enterText(find.byType(TextField), '4607044662964');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    verify(() => repo.resolveGoodByBarcode('4607044662964')).called(1);
    expect(
      find.text(t.stockListScreen.bindPromptBody(barcode: '4607044662964')),
      findsOneWidget,
      reason: 'кладовщику сказали, что ШК неизвестен, и предложили привязать',
    );
    expect(find.text(t.stockListScreen.bindConfirm), findsOneWidget);
    expect(
      queries,
      isEmpty,
      reason: 'скан не уходит в поиск по наименованию — дебаунс отменён',
    );
  });

  testWidgets('Enter по тексту ищет подстрокой, ШК не резолвим', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(theme: buildAppTheme(), home: const GoodsListPage()),
    );
    await tester.pumpAndSettle();
    queries.clear();

    await tester.enterText(find.byType(TextField), 'арахис');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(queries.last, 'арахис', reason: 'запрос ушёл сразу, без дебаунса');
    verifyNever(() => repo.resolveGoodByBarcode(any()));
  });

  testWidgets('тап по товару сразу после ввода не оставляет отложенный запрос', (
    tester,
  ) async {
    // Воспроизведение долга: экран списка при переходе в карточку не уничтожается,
    // и таймер дебаунса, заведённый последней буквой, доработал бы уже из-под карточки.
    // При просадке связи его ошибка подменяла список, и кладовщик возвращался
    // на экран ошибки, хотя поиска не касался.
    await tester.pumpWidget(
      MaterialApp(theme: buildAppTheme(), home: const GoodsListPage()),
    );
    await tester.pumpAndSettle();
    queries.clear();

    await tester.enterText(find.byType(TextField), 'арахис');
    await tester.pump(const Duration(milliseconds: 100)); // дебаунс ещё тикает

    // Тап по товару. Роутера в тесте нет, поэтому push бросит исключение — но отмена
    // отложенного поиска происходит ДО него, и проверяем мы именно её.
    await tester.tap(find.text('Арахис жареный'));
    await tester.pump();
    tester.takeException();

    await tester.pump(const Duration(milliseconds: 600));
    expect(
      queries,
      isEmpty,
      reason: 'отложенный запрос должен быть отменён уходом в карточку',
    );
  });
}
