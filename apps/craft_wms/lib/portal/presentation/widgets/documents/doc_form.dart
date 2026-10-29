import '../../../../core/gen/strings.g.dart';
import '../../../../core/utils/doc_number.dart';
import '../../../data/documents_repository.dart';

/// Две строки ячейки таблицы: основная и пояснение под ней (пусто — нет).
typedef CellText = ({String main, String sub});

/// Что показывать в таблице документов для одной формы (ADHOC-26).
///
/// Каркас вкладки общий: поиск, фильтры, колонки «Документ», «Статус», «Действия». Форма
/// документа решает, что лежит в колонке документа, есть ли колонка контрагента и как она
/// называется, по каким полям ищет поиск. Новая форма — новая ветка здесь, а не новая вкладка.
class DocForm {
  const DocForm._(this.kind);

  /// Описание формы по её коду (`receipt`, `movement`, `stock_entry`, `stocktake`).
  factory DocForm.of(String kind) => DocForm._(kind);

  final String kind;

  /// Подсказка в поле поиска.
  String get searchHint => switch (kind) {
    'receipt' => t.portal.receipt.search,
    'movement' => t.portal.movement.search,
    _ => t.portal.inventory.search,
  };

  /// Заголовок колонки контрагента; `null` — колонки нет (у ввода остатков контрагента нет).
  String? get partyTitle => switch (kind) {
    'receipt' => t.portal.receipt.colParty,
    'movement' => t.portal.movement.colParty,
    _ => null,
  };

  /// Заголовок колонки времени: когда операция прошла на ТСД.
  String get timeTitle => switch (kind) {
    'receipt' => t.portal.receipt.colTime,
    'movement' => t.portal.movement.colTime,
    _ => t.portal.inventory.colTime,
  };

  /// Колонка «Документ» (ADHOC-55): номер документа и под ним операция с её номером —
  /// «ДД-000003», «Перемещение ПМ-000001». По обоим номерам документ находит поиск.
  CellText document(PortalDoc doc) => (main: docTitle(doc), sub: operation(doc));

  /// Номер документа — счётчик своей формы.
  String docTitle(PortalDoc doc) => docNumber(switch (kind) {
    'receipt' => DocKind.receiptDoc,
    'movement' => DocKind.movementDoc,
    'stocktake' => DocKind.stocktakeDoc,
    _ => DocKind.stockEntryDoc,
  }, doc.number);

  /// Операция-источник документа с её номером; номера нет — только вид операции.
  String operation(PortalDoc doc) {
    final (name, docKind, number) = switch (kind) {
      'receipt' => (t.portal.receipt.op, DocKind.receipt, doc.sourceNumber),
      'movement' => (
        _operation(doc.operation),
        operationDocKind(doc.operation),
        doc.sourceNumber,
      ),
      'stocktake' => (
        t.portal.stocktake.mark,
        DocKind.stocktake,
        doc.stocktakeNumber,
      ),
      _ => (t.portal.inventory.mark, DocKind.stockEntry, doc.sourceNumber),
    };
    if (docKind == null || number == 0) return name;
    if (kind == 'stocktake') {
      return t.portal.stocktake.doc(number: docNumber(docKind, number));
    }
    return t.portal.documents.operation(
      name: name,
      number: docNumber(docKind, number),
    );
  }

  /// Первая строка карточки на узком экране (ADHOC-26): номер документа и операция.
  String cardTitle(PortalDoc doc) => '${docTitle(doc)} · ${operation(doc)}';

  /// Колонка контрагента. Поступление — поставщик и его накладная; движение размещения —
  /// задание и то, из чего оно родилось: поставщик и накладная приёмки или проблема склада
  /// (ADHOC-55); у перемещения основания нет — под этим его исполнитель.
  CellText party(PortalDoc doc) {
    if (kind == 'movement' && doc.taskNumber == 0) {
      return (main: t.portal.movement.noBasis, sub: doc.executor);
    }
    final supplier = doc.supplier.isEmpty
        ? t.portal.receipt.noSupplier
        : doc.supplier;
    final ref = doc.docNumber.isEmpty
        ? t.portal.documents.noSupplierDoc
        : t.portal.receipt.doc(number: doc.docNumber, date: _date(doc.docDate));
    if (kind != 'movement') return (main: supplier, sub: ref);
    final task = t.portal.movement.task(
      number: docNumber(DocKind.task, doc.taskNumber),
    );
    if (doc.problemNumber > 0) {
      return (
        main: task,
        sub: t.portal.problems.number(
          number: docNumber(DocKind.problem, doc.problemNumber),
        ),
      );
    }
    return (main: task, sub: '$supplier · $ref');
  }

  /// Колонка времени: дата и время операции в локальной зоне.
  CellText time(PortalDoc doc) {
    final l = doc.createdAt.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return (
      main: '${two(l.day)}.${two(l.month)}.${l.year}',
      sub: '${two(l.hour)}:${two(l.minute)}',
    );
  }

  /// Текст, по которому ищет поиск: всё, что видно в строке.
  ///
  /// Номера — ещё и коротко, без ведущих нулей: «ПМ-1» и «ПМ1» находят «ПМ-000001».
  String searchText(PortalDoc doc) {
    final d = document(doc), p = party(doc), tm = time(doc);
    return [
      d.main,
      d.sub,
      if (partyTitle != null) ...[p.main, p.sub],
      tm.main,
      ...shortDocNumbers('${d.main} ${d.sub} ${p.main} ${p.sub}'),
    ].join(' ');
  }

  /// Дата накладной: с сервера приходит `ДД-ММ-ГГГГ`, показываем через точки.
  static String _date(String raw) => raw.replaceAll('-', '.');

  /// Операция «Движения» для человека; незнакомая показывается как есть.
  static String _operation(String op) => switch (op) {
    'putaway' => t.portal.movement.opPutaway,
    'move' => t.portal.movement.opMove,
    'replenish' => t.portal.movement.opReplenish,
    _ => op,
  };
}
