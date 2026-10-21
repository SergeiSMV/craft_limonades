import 'package:craft_wms/core/error/failure.dart';
import 'package:craft_wms/core/gen/strings.g.dart';
import 'package:craft_wms/features/contents/domain/stock_entities.dart';
import 'package:craft_wms/features/stock/data/catalog_models.dart';
import 'package:craft_wms/features/stock/data/catalog_repository.dart';
import 'package:craft_wms/features/stock/presentation/bloc/stock_detail_cubit.dart';
import 'package:craft_wms/features/stock/presentation/widgets/stock_detail/bind_barcode_dialog.dart';
import 'package:craft_wms/features/stock/presentation/widgets/stock_detail/stock_detail_body.dart';
import 'package:either_dart/either.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../support/contents_stubs.dart';
import '../../support/fake_scanner_service.dart';

class _MockRepo extends Mock implements CatalogRepository {}

/// Привязка ШК из карточки товара (P-FS-17): кнопка вместо пустой секции, диалог со сканом,
/// обновление карточки после привязки и конфликт 409.
void main() {
  const good = Good(id: 'g1', code: '15567', name: 'Арахис жареный', uom: 'шт');

  // Диалог привязки подписан на поток сканера (ADHOC-07), поэтому без зарегистрированного
  // ScannerService он не собирается вовсе.
  late FakeScannerService scanner;
  setUp(() => scanner = registerFakeScanner());
  tearDown(() => scanner.dispose());

  /// ШК, который «занят» другим товаром — на него мок отдаёт 409.
  const conflictCode = '4607044663442';

  /// ШК, на который мок отдаёт «нет связи» — как офлайн на устройстве.
  const offlineCode = '4607044660205';

  /// Поднять карточку товара с заданным набором привязанных ШК.
  Future<_MockRepo> pumpCard(
    WidgetTester tester,
    List<Barcode> barcodes,
  ) async {
    LocaleSettings.useDeviceLocale();
    final repo = _MockRepo();
    var current = barcodes;

    when(() => repo.listGoodBarcodes('g1')).thenAnswer((_) async {
      return Right(current);
    });
    when(
      () => repo.bindBarcode(
        goodId: any(named: 'goodId'),
        barcode: any(named: 'barcode'),
      ),
    ).thenAnswer((inv) async {
      final code = inv.namedArguments[#barcode] as String;
      if (code == conflictCode) return const Left(Failure.server(409));
      if (code == offlineCode) {
        // Договор репозитория (P2-06): без связи привязка всё равно ложится в кэш с пометкой
        // «ожидает», а вызывающему возвращается отказ. Мок повторяет это, иначе тест проверял
        // бы не то, что происходит на самом деле.
        current = [...current, Barcode(barcode: code, pending: true)];
        return const Left(Failure.network());
      }
      current = [...current, Barcode(barcode: code)];
      return const Right(null);
    });

    await tester.pumpWidget(
      BlocProvider(
        create: (_) => StockDetailCubit(
          repo,
          FakeContentsRepository()
            ..places = const [
              StockPlace(
                goodId: 'g1',
                cellId: 'c1',
                cellAddress: 'M1-2-1-2',
                productionDate: '03-08-2026',
                qty: 10,
              ),
            ],
          FakeContentsSnapshotSync(),
        )..load('g1'),
        child: const MaterialApp(
          home: Scaffold(body: StockDetailBody(good: good)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return repo;
  }

  /// Открыть диалог привязки и ввести код со «сканера» (строка + Enter).
  Future<void> scan(WidgetTester tester, String code) async {
    await tester.tap(find.text(t.stockDetailScreen.bindBarcode));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), code);
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
  }

  testWidgets('ШК нет — вместо секции одна кнопка привязки', (tester) async {
    await pumpCard(tester, const []);

    expect(find.text(t.stockDetailScreen.bindBarcode), findsOneWidget);
    expect(
      find.textContaining('Штрихкоды'),
      findsNothing,
      reason: 'пустой сворачиваемый блок не показываем',
    );
  });

  testWidgets('ШК есть — кнопка внутри секции, под списком', (tester) async {
    await pumpCard(tester, const [Barcode(barcode: '4607044662964')]);

    expect(find.textContaining('Штрихкоды (1)'), findsOneWidget);
    expect(find.text(t.stockDetailScreen.bindBarcode), findsOneWidget);
  });

  testWidgets('пустое поле — кнопка «Привязать» выключена', (tester) async {
    await pumpCard(tester, const []);
    await tester.tap(find.text(t.stockDetailScreen.bindBarcode));
    await tester.pumpAndSettle();

    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, t.stockDetailScreen.bindSubmit),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('скан + Enter привязывает и обновляет карточку', (tester) async {
    final repo = await pumpCard(tester, const []);
    await scan(tester, '4607044662964');

    verify(
      () => repo.bindBarcode(goodId: 'g1', barcode: '4607044662964'),
    ).called(1);
    expect(find.byType(AlertDialog), findsNothing, reason: 'диалог закрылся');
    expect(
      find.textContaining('Штрихкоды (1)'),
      findsOneWidget,
      reason: 'карточка перечитана с сервера',
    );
  });

  // ADHOC-11, находка с устройства: операция уже принята в очередь (P2-03), а диалог
  // оставался открытым с заполненным полем и активной кнопкой — изображал незаконченное
  // действие. Кладовщик нажал «Привязать» четыре раза без единого видимого изменения.
  testWidgets('без связи диалог закрывается, а карточка сообщает об отсрочке', (
    tester,
  ) async {
    await pumpCard(tester, const []);

    await scan(tester, offlineCode);

    expect(
      find.byType(BindBarcodeDialog),
      findsNothing,
      reason: 'работа принята, от кладовщика больше ничего не нужно',
    );
    expect(find.text(t.stockDetailScreen.bindOffline), findsOneWidget);
  });

  // P2-06: решение ADHOC-11 пересмотрено. Отложенная привязка теперь видна сразу — кладовщик
  // привязал ШК без связи и должен увидеть результат, иначе решит, что работа пропала. Но
  // с пометкой: операция ещё в очереди и может быть отклонена, тогда строка исчезнет сама.
  testWidgets('отложенный ШК виден в списке, но помечен как неподтверждённый', (
    tester,
  ) async {
    await pumpCard(tester, const [
      Barcode(barcode: offlineCode, pending: true),
    ]);

    expect(find.text(offlineCode), findsOneWidget);
    expect(find.text(t.stockDetailScreen.barcodePending), findsOneWidget);
  });

  testWidgets('подтверждённый ШК пометки не носит', (tester) async {
    await pumpCard(tester, const [Barcode(barcode: '4607044662964')]);

    expect(find.text(t.stockDetailScreen.barcodePending), findsNothing);
  });

  // ADHOC-12, найдено на устройстве: карточка перезагружалась только при успехе, поэтому
  // отложенная привязка в неё не попадала — кладовщик видел прежний список и считал, что
  // работа пропала. При этом в кэше она уже лежала.
  testWidgets('отложенная привязка появляется в карточке с пометкой', (
    tester,
  ) async {
    await pumpCard(tester, const []);

    await scan(tester, offlineCode);

    expect(find.text(offlineCode), findsOneWidget);
    expect(find.text(t.stockDetailScreen.barcodePending), findsOneWidget);
    expect(
      find.text(t.stockDetailScreen.bindOffline),
      findsOneWidget,
      reason: 'и сообщение об отсрочке на месте',
    );
  });

  // ADHOC-12: на «Отмене» оставался pop(false) со времён, когда диалог возвращал bool.
  // showDialog<BindOutcome> получал false и падал на приведении типа — диалог не закрывался.
  testWidgets('«Отмена» закрывает диалог без ошибки типа', (tester) async {
    await pumpCard(tester, const []);
    await tester.tap(find.text(t.stockDetailScreen.bindBarcode));
    await tester.pumpAndSettle();
    expect(find.byType(BindBarcodeDialog), findsOneWidget);

    await tester.tap(find.text(t.stockDetailScreen.cancel));
    await tester.pumpAndSettle();

    expect(find.byType(BindBarcodeDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('409 — ошибка в диалоге, диалог остаётся открытым', (
    tester,
  ) async {
    await pumpCard(tester, const []);
    await scan(tester, conflictCode);

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text(t.stockDetailScreen.bindConflict), findsOneWidget);
    expect(
      find.text(conflictCode),
      findsOneWidget,
      reason: 'код остался в поле — можно пересканировать',
    );
  });

  testWidgets('поле стартует без клавиатуры, по тапу — с обычной', (
    tester,
  ) async {
    await pumpCard(tester, const []);
    await tester.tap(find.text(t.stockDetailScreen.bindBarcode));
    await tester.pumpAndSettle();

    // Соединение с IME создаётся при получении фокуса и живёт с этой конфигурацией:
    // на старте — none (клавиатура не открывается и не мелькает).
    expect(
      tester.testTextInput.setClientArgs?['inputType']['name'],
      'TextInputType.none',
    );

    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();

    // По тапу связь пересоздаётся обычным текстовым полем — иначе клавиатура не открылась бы.
    expect(
      tester.testTextInput.setClientArgs?['inputType']['name'],
      'TextInputType.text',
    );
    expect(
      tester.widget<TextField>(find.byType(TextField)).focusNode?.hasFocus,
      isTrue,
      reason: 'фокус вернулся после пересоздания связи',
    );
  });
}
