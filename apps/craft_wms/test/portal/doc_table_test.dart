import 'package:craft_wms/core/gen/strings.g.dart';
import 'package:craft_wms/portal/data/documents_repository.dart';
import 'package:craft_wms/portal/presentation/widgets/common/neumorphic_plate.dart';
import 'package:craft_wms/portal/presentation/widgets/documents/doc_card.dart';
import 'package:craft_wms/portal/presentation/widgets/documents/doc_form.dart';
import 'package:craft_wms/portal/presentation/widgets/documents/doc_table.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// ADHOC-26: таблица документов — статусы, действия по состоянию, пустой поиск, узкое окно.
void main() {
  setUp(LocaleSettings.useDeviceLocale);

  // Настоящий шрифт портала, а не тестовый: тестовый шире Inter почти вдвое, и с ним ширины
  // колонок и кнопок не похожи на то, что видит оператор (ADHOC-26).
  setUpAll(() async {
    final loader = FontLoader('Inter');
    for (final w in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
      loader.addFont(rootBundle.load('assets/fonts/Inter/Inter-$w.otf'));
    }
    await loader.load();
  });

  PortalDoc doc(String id, DocStatus st, String supplier) => PortalDoc(
    id: id,
    kind: 'receipt',
    supplier: supplier,
    docNumber: 'ТН-$id',
    docDate: '01-10-2026',
    warehouseCode: 'SHB',
    warehouseName: 'Шабулина',
    createdAt: DateTime(2026, 10, 9, 19, 5),
    linesCount: 1,
    status: st,
    number: int.parse(id),
    sourceNumber: int.parse(id),
  );

  Future<void> pump(
    WidgetTester tester,
    List<PortalDoc> docs, {
    double width = 1100,
  }) async {
    tester.view.physicalSize = Size(width, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: DocTable(
              form: DocForm.of('receipt'),
              docs: docs,
              downloading: const {},
              posting: const {},
              onDownload: (_) {},
              onPost: (_) {},
              onHistory: (_) {},
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('ожидающий — «Провести» есть, проведённый — нет', (tester) async {
    await pump(tester, [
      doc('1', DocStatus.downloaded, 'ИП Лапушкин'),
      doc('2', DocStatus.done, 'ИП Березин'),
    ]);
    expect(tester.takeException(), isNull);
    expect(find.text(t.portal.documents.statusWaiting), findsOneWidget);
    expect(find.text(t.portal.documents.statusPosted), findsOneWidget);
    expect(
      find.text(t.portal.documents.post),
      findsOneWidget,
      reason: 'только у ожидающего',
    );
    expect(find.text(t.portal.documents.xlsx), findsNWidgets(2));
  });

  // «Нет исключения» мало: Table не сообщает о переполнении, а плашка молча обрезает всё,
  // что шире неё. Поэтому кнопки действий должны лежать внутри своей плашки — таблицы или
  // карточки; иначе оператор их не видит (так было на ширине ноутбука).
  void expectActionsVisible(WidgetTester tester, [double? _]) {
    for (final icon in [Icons.schedule, Icons.download, Icons.check]) {
      for (final e in find.byIcon(icon).evaluate()) {
        final button = find.byWidget(e.widget).first;
        final plate = find
            .ancestor(of: button, matching: find.byType(NeumorphicPlate))
            .first;
        expect(
          tester.getRect(button).right,
          lessThanOrEqualTo(tester.getRect(plate).right),
          reason: 'кнопка $icon за краем плашки',
        );
      }
    }
  }

  testWidgets('широкое окно — кнопки с подписями и все в окне', (tester) async {
    await pump(tester, [
      doc('1', DocStatus.isNew, 'ИП ЛАПУШКИН СЕРГЕЙ АНДРЕЕВИЧ'),
    ]);
    expect(tester.takeException(), isNull);
    expect(find.text(t.portal.documents.xlsx), findsOneWidget);
    expectActionsVisible(tester, 1100);
  });

  testWidgets('окно ноутбука — кнопки иконками, без прокрутки, все в окне', (
    tester,
  ) async {
    await pump(tester, [
      doc('1', DocStatus.isNew, 'ИП ЛАПУШКИН СЕРГЕЙ АНДРЕЕВИЧ'),
    ], width: 800);
    expect(tester.takeException(), isNull);
    expect(
      find.text(t.portal.documents.xlsx),
      findsNothing,
      reason: 'подписи сменились иконками',
    );
    expect(
      find.byIcon(Icons.check),
      findsOneWidget,
      reason: '«Провести» иконкой',
    );
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is SingleChildScrollView && w.scrollDirection == Axis.horizontal,
      ),
      findsNothing,
    );
    expectActionsVisible(tester, 800);
  });

  // Бейдж статуса — целиком, без многоточия: колонка статуса берёт ширину по бейджу.
  void expectStatusNotTruncated(WidgetTester tester) {
    for (final label in [
      t.portal.documents.statusPosted,
      t.portal.documents.statusWaiting,
    ]) {
      for (final e in find.text(label).evaluate()) {
        final p = e.findRenderObject()! as RenderParagraph;
        expect(p.didExceedMaxLines, isFalse, reason: 'бейдж «$label» обрезан');
      }
    }
  }

  testWidgets('бейдж статуса не обрезается — на широком окне и на ноутбуке', (
    tester,
  ) async {
    final docs = [
      doc('1', DocStatus.done, 'АО "ФАРМ"'),
      doc('2', DocStatus.isNew, 'ИП Березин'),
    ];
    for (final width in [1100.0, 800.0]) {
      await pump(tester, docs, width: width);
      expect(tester.takeException(), isNull);
      expectStatusNotTruncated(tester);
    }
  });

  testWidgets('на любой ширине действия внутри плашки — таблица или карточки', (
    tester,
  ) async {
    final docs = [
      doc('1', DocStatus.isNew, 'ИП ЛАПУШКИН СЕРГЕЙ АНДРЕЕВИЧ'),
      doc('2', DocStatus.done, 'ИП Березин Алексей Васильевич'),
    ];
    for (final width in [
      375.0,
      560.0,
      680.0,
      740.0,
      800.0,
      860.0,
      920.0,
      1100.0,
      1300.0,
    ]) {
      await pump(tester, docs, width: width);
      expect(tester.takeException(), isNull, reason: 'ширина $width');
      expectActionsVisible(tester);
    }
  });

  testWidgets(
    'кнопки строк — в одну колонку: «История» и «Скачать» на одних местах',
    (tester) async {
      await pump(tester, [
        doc('1', DocStatus.isNew, 'ИП Лапушкин'),
        doc('2', DocStatus.done, 'АО "ФАРМ"'),
      ]);
      for (final icon in [Icons.schedule, Icons.download]) {
        final xs = find
            .byIcon(icon)
            .evaluate()
            .map((e) => tester.getRect(find.byWidget(e.widget).first).left)
            .toSet();
        expect(
          xs,
          hasLength(1),
          reason: 'кнопки $icon стоят в разных местах строк: $xs',
        );
      }
    },
  );

  testWidgets('пусто после поиска — «Ничего не найдено»', (tester) async {
    await pump(tester, const []);
    expect(find.text(t.portal.documents.notFound), findsOneWidget);
  });

  testWidgets(
    'телефон — карточки вместо таблицы, кнопки в экране, у проведённого галочка',
    (tester) async {
      await pump(tester, [
        doc('1', DocStatus.isNew, 'ИП ЛАПУШКИН СЕРГЕЙ АНДРЕЕВИЧ'),
        doc('2', DocStatus.done, 'АО "ФАРМ"'),
      ], width: 375);
      expect(tester.takeException(), isNull);
      expect(find.byType(Table), findsNothing);
      expect(find.byType(DocCard), findsNWidgets(2));
      expect(
        find.byIcon(Icons.check),
        findsOneWidget,
        reason: '«Провести» только у ожидающего',
      );
      expect(
        find.byIcon(Icons.task_alt),
        findsOneWidget,
        reason: 'галочка у проведённого',
      );
      expect(
        find.text('ДП-000001 · Приёмка ПР-000001'),
        findsOneWidget,
        reason: 'документ первой строкой',
      );
      expectActionsVisible(tester, 375);
    },
  );
}
