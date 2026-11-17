import 'package:craft_wms/core/di/injection.dart';
import 'package:craft_wms/core/error/failure.dart';
import 'package:craft_wms/core/widgets/good_picker_sheet.dart';
import 'package:craft_wms/core/gen/strings.g.dart';
import 'package:craft_wms/core/theme/app_theme.dart';
import 'package:craft_wms/features/stock/data/catalog_models.dart';
import 'package:craft_wms/features/stock/data/catalog_repository.dart';
import 'package:craft_wms/features/stock/presentation/bloc/goods_list_cubit.dart';
import 'package:craft_wms/features/stock/presentation/pages/nomenclature_page.dart';
import 'package:either_dart/either.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../support/fake_scanner_service.dart';

import '../../support/contents_stubs.dart';
import '../../support/entry_draft_stub.dart';

class _MockRepo extends Mock implements CatalogRepository {}

/// «Номенклатура» (до ADHOC-33 - «Остатки»): код с аппаратного сканера идёт тем же путём, что и завершённый ввод в строке поиска.
/// Экран не должен зависеть от того, каким режимом сканера настроено устройство.
void main() {
  late _MockRepo repo;

  setUp(() {
    registerEmptyDraftStore();
    // Адрес ячейки, которой нет в справочнике, остаётся текстом поиска (P5-05).
    registerFakeContentsRepository();
    LocaleSettings.useDeviceLocale();
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
    ).thenAnswer(
      (_) async => const Right(
        Paged<Good>(items: <Good>[], total: 0, limit: 50, offset: 0),
      ),
    );
    if (getIt.isRegistered<GoodsListCubit>()) {
      getIt.unregister<GoodsListCubit>();
    }
    getIt.registerFactory<GoodsListCubit>(() => GoodsListCubit(repo));
    // Лист выбора товара берёт репозиторий из getIt напрямую (как и во «Вводе остатков»).
    if (getIt.isRegistered<CatalogRepository>()) {
      getIt.unregister<CatalogRepository>();
    }
    getIt.registerSingleton<CatalogRepository>(repo);
  });

  Widget wrap() =>
      MaterialApp(theme: buildAppTheme(), home: const NomenclaturePage());

  testWidgets('скан из потока резолвится как штрихкод, а не ищется по имени', (
    tester,
  ) async {
    final scanner = registerFakeScanner();
    when(
      () => repo.resolveGoodByBarcode('4607091380001'),
    ).thenAnswer((_) async => const Right<Failure, Good?>(null));

    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    scanner.emit('4607091380001');
    await tester.pumpAndSettle();

    verify(() => repo.resolveGoodByBarcode('4607091380001')).called(1);
    // Непривязанный ШК - предложение привязать его к товару (ADHOC-06).
    expect(
      find.text(t.stockListScreen.bindPromptBody(barcode: '4607091380001')),
      findsOneWidget,
    );
    await scanner.dispose();
  });

  // ADHOC-06, воспроизведение находки с устройства: в intent-режиме код приходит мимо строки
  // поиска. Код не похож на ШК → уходит в поиск подстрокой, и раньше экран отвечал
  // «товары не найдены» при пустой строке поиска - причина не видна, очистить нечем.
  testWidgets('скан не-ШК: текст виден в строке поиска, а не только в списке', (
    tester,
  ) async {
    final scanner = registerFakeScanner();

    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    scanner.emit('M1-1-10-1');
    await tester.pumpAndSettle();

    verifyNever(() => repo.resolveGoodByBarcode(any()));
    verify(
      () => repo.listGoods(
        query: 'M1-1-10-1',
        groupId: any(named: 'groupId'),
        supplierId: any(named: 'supplierId'),
        limit: any(named: 'limit'),
        offset: any(named: 'offset'),
      ),
    ).called(1);
    expect(find.text('M1-1-10-1'), findsOneWidget); // это строка поиска
    expect(find.text(t.stockListScreen.empty), findsOneWidget);
    await scanner.dispose();
  });

  // ADHOC-06: офлайн промах локальной базы неотличим от привязки, сделанной на другом
  // терминале, - утверждать «не привязан ни к одному товару» и предлагать привязку нельзя.
  testWidgets('офлайн: сообщение «нет связи» вместо предложения привязки', (
    tester,
  ) async {
    final scanner = registerFakeScanner();
    when(
      () => repo.resolveGoodByBarcode('4607091380001'),
    ).thenAnswer((_) async => const Left(Failure.network()));

    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    scanner.emit('4607091380001');
    await tester.pumpAndSettle();

    expect(
      find.text(t.stockListScreen.barcodeOffline(barcode: '4607091380001')),
      findsOneWidget,
    );
    expect(find.text(t.stockListScreen.bindPromptTitle), findsNothing);
    // Список загрузился и остался на экране: отказ резолва его не подменяет.
    expect(find.text(t.stockListScreen.error), findsNothing);
    await scanner.dispose();
  });

  // ADHOC-06: непривязанный ШК на «Остатках» перестал быть тупиком. Раньше кладовщик получал
  // сообщение, код терялся, и чтобы привязать ШК, товар надо было найти руками, открыть карточку
  // и отсканировать заново.
  //
  // Привязку в тесте проваливаем намеренно: успешная уводит в карточку товара, а роутера здесь
  // нет - переход бросает уже после теста и перехватить его нечем. Тракт до записи (диалог →
  // лист выбора → вызов с верными аргументами) один и тот же, а показ ошибки проверяется заодно.
  testWidgets(
    'привязка непривязанного ШК: подтверждение → выбор товара → запись',
    (tester) async {
      final scanner = registerFakeScanner();
      const picked = Good(id: 'g7', name: 'Арахис жареный', uom: 'шт');
      when(
        () => repo.resolveGoodByBarcode('4607091380001'),
      ).thenAnswer((_) async => const Right<Failure, Good?>(null));
      when(
        () => repo.listGoods(
          query: any(named: 'query'),
          groupId: any(named: 'groupId'),
          supplierId: any(named: 'supplierId'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        ),
      ).thenAnswer(
        (_) async => const Right(
          Paged<Good>(items: [picked], total: 1, limit: 50, offset: 0),
        ),
      );
      when(
        () => repo.bindBarcode(
          goodId: any(named: 'goodId'),
          barcode: any(named: 'barcode'),
        ),
      ).thenAnswer((_) async => const Left(Failure.server(409)));

      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      scanner.emit('4607091380001');
      await tester.pumpAndSettle();

      await tester.tap(find.text(t.stockListScreen.bindConfirm));
      await tester.pumpAndSettle();

      // Товар ищем внутри листа: тот же товар показан и в списке за ним.
      await tester.tap(
        find.descendant(
          of: find.byType(GoodPickerSheet),
          matching: find.text('Арахис жареный'),
        ),
      );
      await tester.pumpAndSettle();

      verify(
        () => repo.bindBarcode(goodId: 'g7', barcode: '4607091380001'),
      ).called(1);
      expect(find.text(t.stockListScreen.bindFailed), findsOneWidget);
      await scanner.dispose();
    },
  );

  testWidgets('отказ от привязки: выбор товара не открывается, записи нет', (
    tester,
  ) async {
    final scanner = registerFakeScanner();
    when(
      () => repo.resolveGoodByBarcode('4607091380001'),
    ).thenAnswer((_) async => const Right<Failure, Good?>(null));

    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    scanner.emit('4607091380001');
    await tester.pumpAndSettle();

    await tester.tap(find.text(t.stockListScreen.bindCancel));
    await tester.pumpAndSettle();

    expect(find.byType(GoodPickerSheet), findsNothing);
    verifyNever(
      () => repo.bindBarcode(
        goodId: any(named: 'goodId'),
        barcode: any(named: 'barcode'),
      ),
    );
    await scanner.dispose();
  });
}
