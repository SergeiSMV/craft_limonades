import '../../../../core/gen/strings.g.dart';
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

  /// Описание формы по её коду (`receipt`, `movement`, `stock_entry`).
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

  /// Колонка «Документ». Поступление — номер накладной и её дата; движение — задание
  /// и операция, а без задания (перемещение, P6-07) — операция и исполнитель; ввод
  /// остатков — название и число позиций.
  CellText document(PortalDoc doc) => switch (kind) {
    'receipt' =>
      doc.docNumber.isEmpty
          ? (main: '—', sub: t.portal.documents.noSupplierDoc)
          : (
              main: doc.docNumber,
              sub: t.portal.documents.docDate(date: _date(doc.docDate)),
            ),
    'movement' when doc.taskNumber == 0 => (
      main: _operation(doc.operation),
      sub: doc.executor,
    ),
    'movement' => (
      main: t.portal.movement.task(number: doc.taskNumber),
      sub: _operation(doc.operation),
    ),
    _ => (
      main: t.portal.inventory.mark,
      sub: t.portal.documents.lines(count: doc.linesCount),
    ),
  };

  /// Первая строка карточки на узком экране (ADHOC-26): документ одной строкой, без числа
  /// позиций. Поступление — «№ … от …»; движение — задание и операция; ввод остатков — название.
  String cardTitle(PortalDoc doc) => switch (kind) {
    'receipt' =>
      doc.docNumber.isEmpty
          ? t.portal.documents.noSupplierDoc
          : t.portal.receipt.doc(
              number: doc.docNumber,
              date: _date(doc.docDate),
            ),
    'movement' when doc.taskNumber == 0 => _operation(doc.operation),
    'movement' => '${document(doc).main} · ${_operation(doc.operation)}',
    _ => t.portal.inventory.mark,
  };

  /// Колонка контрагента. Поступление — поставщик; движение — поставщик и накладная приёмки,
  /// из которой родилось задание; у перемещения основания нет.
  CellText party(PortalDoc doc) {
    if (kind == 'movement' && doc.taskNumber == 0) {
      return (main: t.portal.movement.noBasis, sub: '');
    }
    final supplier = doc.supplier.isEmpty
        ? t.portal.receipt.noSupplier
        : doc.supplier;
    if (kind != 'movement') return (main: supplier, sub: '');
    final ref = doc.docNumber.isEmpty
        ? t.portal.documents.noSupplierDoc
        : t.portal.receipt.doc(number: doc.docNumber, date: _date(doc.docDate));
    return (main: supplier, sub: ref);
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
  String searchText(PortalDoc doc) {
    final d = document(doc), p = party(doc), tm = time(doc);
    return [
      d.main,
      d.sub,
      if (partyTitle != null) ...[p.main, p.sub],
      tm.main,
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
