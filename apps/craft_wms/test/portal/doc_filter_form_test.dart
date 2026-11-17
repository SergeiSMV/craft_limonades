import 'package:craft_wms/core/gen/strings.g.dart';
import 'package:craft_wms/portal/domain/documents/documents_repository.dart';
import 'package:craft_wms/portal/presentation/widgets/documents/doc_filter.dart';
import 'package:craft_wms/portal/presentation/widgets/documents/doc_form.dart';
import 'package:flutter_test/flutter_test.dart';

// ADHOC-26: фильтр по состоянию в 1С, поиск и содержимое колонок по форме документа.
PortalDoc doc(
  String id, {
  String kind = 'receipt',
  DocStatus status = DocStatus.isNew,
  String supplier = '',
  String docNumber = '',
  String docDate = '',
  String operation = '',
  int taskNumber = 0,
  String executor = '',
  int lines = 1,
  int number = 0,
  int sourceNumber = 0,
}) => PortalDoc(
  id: id,
  kind: kind,
  supplier: supplier,
  docNumber: docNumber,
  docDate: docDate,
  operation: operation,
  taskNumber: taskNumber,
  executor: executor,
  warehouseCode: 'SHB',
  warehouseName: 'Шабулина',
  createdAt: DateTime(2026, 10, 9, 19, 5),
  linesCount: lines,
  status: status,
  number: number,
  sourceNumber: sourceNumber,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(LocaleSettings.useDeviceLocale);

  group('фильтр', () {
    final docs = [
      doc('new', status: DocStatus.isNew, supplier: 'ИП Лапушкин'),
      doc(
        'dl',
        status: DocStatus.downloaded,
        supplier: 'АО "ФАРМ"',
        docNumber: '4562655Н',
      ),
      doc('done', status: DocStatus.done, supplier: 'ИП Березин'),
    ];

    test('«новый» и «скачан» - оба ожидают 1С; счётчики по всему списку', () {
      expect(countByFilter(docs), {
        DocFilter.all: 3,
        DocFilter.waiting: 2,
        DocFilter.posted: 1,
      });
      final waiting = applyFilter(
        docs,
        filter: DocFilter.waiting,
        query: '',
        searchText: (_) => '',
      );
      expect(waiting.map((d) => d.id), ['new', 'dl']);
    });

    test(
      'поиск без учёта регистра, вместе с фильтром, порядок сервера сохраняется',
      () {
        final form = DocForm.of('receipt');
        List<String> find(String q, DocFilter f) => applyFilter(
          docs,
          filter: f,
          query: q,
          searchText: form.searchText,
        ).map((d) => d.id).toList();
        expect(find('лапушкин', DocFilter.all), ['new']);
        expect(find('4562', DocFilter.all), [
          'dl',
        ], reason: 'по номеру накладной');
        expect(find('ип', DocFilter.posted), ['done']);
        expect(find('  ', DocFilter.all), [
          'new',
          'dl',
          'done',
        ], reason: 'пустой запрос не отсекает');
      },
    );
  });

  group('колонки по форме', () {
    test('поступление: номер документа и приёмки; поставщик и накладная', () {
      final f = DocForm.of('receipt');
      expect(f.partyTitle, isNotNull);
      final withDoc = doc(
        'a',
        supplier: 'ИП Лапушкин',
        docNumber: '4562655Н',
        docDate: '07-10-2026',
        number: 3,
        sourceNumber: 12,
      );
      expect(f.document(withDoc), (
        main: 'ДП-000003',
        sub: 'Приёмка ПР-000012',
      ));
      expect(f.party(withDoc), (
        main: 'ИП Лапушкин',
        sub: '№ 4562655Н от 07.10.2026',
      ));
      expect(f.party(doc('b')), (
        main: t.portal.receipt.noSupplier,
        sub: t.portal.documents.noSupplierDoc,
      ));
    });

    test('движение: номер документа и размещения, основание - задание', () {
      final f = DocForm.of('movement');
      final m = doc(
        'm',
        kind: 'movement',
        taskNumber: 57,
        operation: 'putaway',
        supplier: 'ИП Лапушкин',
        docNumber: 'ТН-1',
        docDate: '01-10-2026',
        number: 4,
        sourceNumber: 9,
      );
      expect(f.document(m), (main: 'ДД-000004', sub: 'Размещение РЗ-000009'));
      expect(f.party(m), (
        main: 'Задание ЗД-000057',
        sub: 'ИП Лапушкин · № ТН-1 от 01.10.2026',
      ));
    });

    // P6-07: перемещение идёт без задания - основания нет, под этим исполнитель.
    test('перемещение: номер операции, без основания, исполнитель', () {
      final f = DocForm.of('movement');
      final m = doc(
        'mv',
        kind: 'movement',
        operation: 'move',
        executor: 'Иванов Иван',
        number: 2,
        sourceNumber: 1,
      );
      expect(f.document(m), (main: 'ДД-000002', sub: 'Перемещение ПМ-000001'));
      expect(f.party(m), (
        main: t.portal.movement.noBasis,
        sub: 'Иванов Иван',
      ));
      expect(f.searchText(m), contains('Иванов Иван'));
    });

    test('поиск по номеру - полному и короткому', () {
      final f = DocForm.of('movement');
      final m = doc(
        'mv',
        kind: 'movement',
        operation: 'move',
        number: 2,
        sourceNumber: 1,
      );
      final text = f.searchText(m).toLowerCase();
      for (final q in ['пм-000001', 'пм-1', 'пм1', 'дд-2', 'дд2']) {
        expect(text, contains(q), reason: q);
      }
    });

    test('ввод остатков: без колонки контрагента, номера документа и операции', () {
      final f = DocForm.of('stock_entry');
      expect(f.partyTitle, isNull);
      expect(
        f.document(doc('s', kind: 'stock_entry', number: 1, sourceNumber: 5)),
        (main: 'ДВ-000001', sub: 'Ввод остатков ВО-000005'),
      );
    });

    test('без номера операции - только её вид', () {
      expect(DocForm.of('receipt').document(doc('a')).sub, 'Приёмка');
    });

    test('время - дата и часы в локальной зоне', () {
      expect(DocForm.of('receipt').time(doc('t')), (
        main: '09.10.2026',
        sub: '19:05',
      ));
    });
  });
}
