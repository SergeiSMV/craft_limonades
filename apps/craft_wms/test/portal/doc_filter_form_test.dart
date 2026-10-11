import 'package:craft_wms/core/gen/strings.g.dart';
import 'package:craft_wms/portal/data/documents_repository.dart';
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
  int lines = 1,
}) => PortalDoc(
  id: id,
  kind: kind,
  supplier: supplier,
  docNumber: docNumber,
  docDate: docDate,
  operation: operation,
  taskNumber: taskNumber,
  warehouseCode: 'SHB',
  warehouseName: 'Шабулина',
  createdAt: DateTime(2026, 10, 9, 19, 5),
  linesCount: lines,
  status: status,
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

    test('«новый» и «скачан» — оба ожидают 1С; счётчики по всему списку', () {
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
    test('поступление: накладная или прочерк, поставщик', () {
      final f = DocForm.of('receipt');
      expect(f.partyTitle, isNotNull);
      final withDoc = doc(
        'a',
        supplier: 'ИП Лапушкин',
        docNumber: '4562655Н',
        docDate: '07-10-2026',
      );
      expect(f.document(withDoc), (main: '4562655Н', sub: 'от 07.10.2026'));
      expect(f.party(withDoc), (main: 'ИП Лапушкин', sub: ''));
      expect(f.document(doc('b')).main, '—');
      expect(f.party(doc('b')).main, t.portal.receipt.noSupplier);
    });

    test('движение: задание и операция, основание — поставщик и накладная', () {
      final f = DocForm.of('movement');
      final m = doc(
        'm',
        kind: 'movement',
        taskNumber: 57,
        operation: 'putaway',
        supplier: 'ИП Лапушкин',
        docNumber: 'ТН-1',
        docDate: '01-10-2026',
      );
      expect(f.document(m), (main: 'Задание № 57', sub: 'Размещение'));
      expect(f.party(m), (main: 'ИП Лапушкин', sub: '№ ТН-1 от 01.10.2026'));
      expect(f.searchText(m), contains('Задание № 57'));
    });

    test('ввод остатков: без колонки контрагента, позиции под названием', () {
      final f = DocForm.of('stock_entry');
      expect(f.partyTitle, isNull);
      expect(f.document(doc('s', kind: 'stock_entry', lines: 214)), (
        main: 'Ввод остатков',
        sub: 'позиций: 214',
      ));
    });

    test(
      'заголовок карточки телефона — документ одной строкой, без позиций',
      () {
        expect(
          DocForm.of(
            'receipt',
          ).cardTitle(doc('a', docNumber: '4562655Н', docDate: '07-10-2026')),
          '№ 4562655Н от 07.10.2026',
        );
        expect(
          DocForm.of('receipt').cardTitle(doc('b')),
          t.portal.documents.noSupplierDoc,
        );
        expect(
          DocForm.of('movement').cardTitle(
            doc('m', kind: 'movement', taskNumber: 5, operation: 'putaway'),
          ),
          'Задание № 5 · Размещение',
        );
        expect(
          DocForm.of(
            'stock_entry',
          ).cardTitle(doc('s', kind: 'stock_entry', lines: 150)),
          'Ввод остатков',
        );
      },
    );

    test('время — дата и часы в локальной зоне', () {
      expect(DocForm.of('receipt').time(doc('t')), (
        main: '09.10.2026',
        sub: '19:05',
      ));
    });
  });
}
