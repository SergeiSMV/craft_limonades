import 'package:either_dart/either.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:injectable/injectable.dart';

import '../../../../core/error/failure.dart';
import '../../../../core/load_unit/load_unit_id_generator.dart';
import '../../../../core/printer/printer_device.dart';
import '../../../../core/printer/printer_service.dart';
import '../../../stock/data/catalog_models.dart';
import '../../../stock/data/catalog_repository.dart';
import '../../data/receipt_draft_store.dart';
import '../../data/receipt_repository.dart';
import 'receipt_models.dart';

part 'receipt_cubit.freezed.dart';

/// Состояние экрана приёмки (P4-09).
///
/// Поток: поставщик → скан товара (привязка или выдача ШК) → дата и количество → строка ложится
/// штучно в текущую ячейку, а на странице короба — в короб (ADHOC-18) → … → «Завершить приёмку».
/// Всё копится на терминале и уходит на сервер одной операцией очереди.
@freezed
abstract class ReceiptState with _$ReceiptState {
  const factory ReceiptState({
    /// Поставщик выбран (или выбрано «без поставщика») — приёмка начата.
    @Default(false) bool started,

    /// Идентификатор документа. Выдаёт терминал: приёмку начинают и без связи.
    String? receiptId,

    /// `null` при начатой приёмке — без поставщика (внутреннее поступление, возврат).
    Supplier? supplier,

    /// Документ поставщика (ADHOC-23). `null` у начатой приёмки — черновик сохранён до того,
    /// как документ стал обязательным: «Завершить» сначала спросит его.
    ReceiptDoc? doc,

    /// Ячейка приёмки по умолчанию («С-Н-П»). Из неё же берётся склад документа.
    Cell? defaultCell,

    /// Куда ложатся штучные строки и новые короба; `null` — в ячейку по умолчанию.
    Cell? targetCell,
    @Default(<ReceiptBox>[]) List<ReceiptBox> boxes,
    @Default(<ReceiptLineDraft>[]) List<ReceiptLineDraft> lines,

    /// Идёт отправка.
    @Default(false) bool busy,

    /// Итог отправки; не `null` — приёмка завершена.
    ReceiptOutcome? outcome,

    /// Причина отказа сервера — для итогового экрана.
    String? rejectReason,
    Failure? failure,
  }) = _ReceiptState;

  const ReceiptState._();

  /// Короб приёмки по идентификатору; `null` — такого нет (удалён или чужой).
  ReceiptBox? boxById(String boxId) =>
      boxes.where((b) => b.id == boxId).firstOrNull;

  /// Строки короба.
  List<ReceiptLineDraft> linesOf(String boxId) =>
      lines.where((l) => l.boxId == boxId).toList();

  /// Сколько строк лежит в коробе.
  int linesInBox(String boxId) => lines.where((l) => l.boxId == boxId).length;

  /// Штучные строки — те, что в общем списке идут отдельно от коробов.
  List<ReceiptLineDraft> get looseLines =>
      lines.where((l) => l.boxId == null).toList();

  /// Можно завершать: есть что оприходовать и отправка не идёт.
  bool get canSubmit => started && lines.isNotEmpty && !busy && outcome == null;
}

/// Cubit приёмки на ТСД (P4-09). Фабрика — свой на экран.
@injectable
class ReceiptCubit extends Cubit<ReceiptState> {
  ReceiptCubit(
    this._catalog,
    this._repo,
    this._drafts,
    this._ids,
    this._printer,
  ) : super(const ReceiptState());

  final CatalogRepository _catalog;
  final ReceiptRepository _repo;
  final ReceiptDraftStore _drafts;
  final LoadUnitIdGenerator _ids;
  final PrinterService _printer;

  /// Очередь записей черновика: два быстрых изменения подряд иначе ушли бы в базу параллельно,
  /// и последней могла бы лечь более ранняя версия приёмки (тот же приём, что у прохода).
  Future<void> _writes = Future<void>.value();

  //* --- черновик --- *//

  /// Восстановить незавершённую приёмку. Зовётся один раз при открытии экрана.
  Future<void> restore() async {
    final draft = await _drafts.load();
    if (draft == null) return;
    emit(_stateFromDraft(draft));
  }

  /// Слепок durable-части состояния. Не входят `busy`, `failure` и итог отправки: они описывают
  /// сетевой вызов, которого после перезапуска уже нет.
  Map<String, dynamic> _draftJson(ReceiptState s) => {
    'receipt_id': s.receiptId,
    'supplier': s.supplier?.toJson(),
    'doc': s.doc?.toJson(),
    'default_cell': s.defaultCell?.toJson(),
    'target_cell': s.targetCell?.toJson(),
    'boxes': s.boxes.map((b) => b.toJson()).toList(),
    'lines': s.lines.map((l) => l.toJson()).toList(),
  };

  /// Состояние из слепка.
  ReceiptState _stateFromDraft(Map<String, dynamic> d) {
    Map<String, dynamic>? map(String key) => d[key] as Map<String, dynamic>?;
    List<dynamic> list(String key) => d[key] as List<dynamic>? ?? const [];
    final supplier = map('supplier');
    final doc = map('doc');
    final defaultCell = map('default_cell');
    final targetCell = map('target_cell');
    return ReceiptState(
      started: true,
      receiptId: d['receipt_id'] as String?,
      supplier: supplier == null ? null : Supplier.fromJson(supplier),
      doc: doc == null ? null : ReceiptDoc.fromJson(doc),
      defaultCell: defaultCell == null ? null : Cell.fromJson(defaultCell),
      targetCell: targetCell == null ? null : Cell.fromJson(targetCell),
      boxes: list(
        'boxes',
      ).map((e) => ReceiptBox.fromJson(e as Map<String, dynamic>)).toList(),
      lines: list('lines')
          .map((e) => ReceiptLineDraft.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  /// Сохранение черновика повешено на [emit], а не на каждый метод-мутацию: метод, добавленный
  /// позже, про сохранение забыл бы, а один перехват на все изменения забыть невозможно.
  @override
  void emit(ReceiptState state) {
    super.emit(state);
    // Отправленная (в том числе поставленная в очередь) приёмка больше не черновик: её копия
    // теперь в очереди операций. Не начатую тоже не храним.
    final done = !state.started || state.outcome != null;
    final snapshot = done ? null : _draftJson(state);
    _writes = _writes
        .then(
          (_) => snapshot == null ? _drafts.clear() : _drafts.save(snapshot),
        )
        // Сбой записи черновика не должен ронять приёмку: кладовщик продолжит, просто без
        // страховки.
        .catchError((_) {});
  }

  /// Дождаться записи черновика — нужно только тестам.
  @visibleForTesting
  Future<void> get draftWrites => _writes;

  /// Отбросить приёмку целиком — по явному требованию кладовщика.
  ///
  /// Напечатанные ярлыки коробов при этом остаются на коробах, а на сервере таких ГЕ не будет:
  /// их скан даст «ГЕ не найдена». Поэтому действие спрятано в меню и требует подтверждения.
  Future<void> discard() async {
    emit(const ReceiptState());
    await _writes;
  }

  //* --- начало --- *//

  /// Начать приёмку от поставщика (`null` — без поставщика) по документу [doc] (ADHOC-23).
  ///
  /// Ячейка по умолчанию нужна сразу: из неё берётся склад документа, и без неё приёмку
  /// не оприходовать. Её отсутствие — незавершённое развёртывание, чинится админом,
  /// поэтому приёмку не начинаем вовсе, а не обнаруживаем это на финале.
  Future<void> start(Supplier? supplier, ReceiptDoc doc) async {
    final res = await _catalog.defaultCell();
    if (res.isLeft) {
      emit(state.copyWith(failure: res.left));
      return;
    }
    final cell = res.right;
    if (cell == null) {
      emit(state.copyWith(failure: const Failure.unknown(kNoDefaultCell)));
      return;
    }
    emit(
      ReceiptState(
        started: true,
        receiptId: _ids.newId(),
        supplier: supplier,
        doc: doc,
        defaultCell: cell,
      ),
    );
  }

  /// Исправить документ поставщика — до завершения приёмки (ADHOC-23).
  void setDoc(ReceiptDoc doc) => emit(state.copyWith(doc: doc));

  //* --- ячейка и короба --- *//

  /// Сменить ячейку для штучных строк и новых коробов. Дефолтная ячейка сбрасывает выбор.
  ///
  /// Уже собранные короба своей ячейки не меняют: у каждого она своя и меняется на странице
  /// короба ([setBoxCell]).
  void setTargetCell(Cell cell) {
    emit(
      state.copyWith(targetCell: cell.isDefault ? null : cell, failure: null),
    );
  }

  /// Новый короб в текущей ячейке. Возвращает идентификатор — по нему открывают страницу
  /// короба. Ярлык печатает кладовщик сам со страницы короба (решение пользователя, ADHOC-18).
  ///
  /// Короб создаётся на терминале, без сети: на сервере ГЕ появится вместе с приёмкой.
  String newBox() {
    final box = ReceiptBox(id: _ids.newId(), cell: state.targetCell);
    emit(state.copyWith(boxes: [...state.boxes, box], failure: null));
    return box.id;
  }

  /// Есть ли в приёмке короб с таким идентификатором (скан ярлыка).
  ///
  /// Короб из другой приёмки сюда не берём: он уже где-то лежит со своим составом, и класть
  /// в него на приёмке значит переместить его, а перемещение — отдельная операция (P6).
  bool hasBox(String loadUnitId) =>
      state.boxById(loadUnitId.toLowerCase()) != null;

  /// Перенести короб в другую ячейку — целиком, вместе со всеми его строками (ADHOC-18).
  ///
  /// Строки короба меняют ячейку вместе с ним: короб не может лежать в двух местах, и сервер
  /// отклонил бы документ, где строки одного короба указывают разные ячейки. Слияния строк
  /// здесь не бывает — внутри короба ячейка у всех строк и так одна.
  void setBoxCell(String boxId, Cell cell) {
    final target = cell.isDefault ? null : cell;
    emit(
      state.copyWith(
        boxes: [
          for (final b in state.boxes)
            b.id == boxId ? b.copyWith(cell: target) : b,
        ],
        lines: [
          for (final l in state.lines)
            l.boxId == boxId ? l.copyWith(cell: target) : l,
        ],
        failure: null,
      ),
    );
  }

  /// Удалить короб вместе с его строками (ADHOC-18).
  ///
  /// Напечатанный ярлык при этом остаётся на коробе, а ГЕ на сервере не появится — поэтому
  /// экран спрашивает подтверждение.
  void removeBox(String boxId) {
    emit(
      state.copyWith(
        boxes: state.boxes.where((b) => b.id != boxId).toList(),
        lines: state.lines.where((l) => l.boxId != boxId).toList(),
        failure: null,
      ),
    );
  }

  //* --- строки --- *//

  /// Резолв товара по ШК — через общий кэш-first репозиторий справочников. Исход целиком:
  /// «ШК не привязан» и «проверить не удалось» — разные вещи (ADHOC-06).
  Future<Either<Failure, Good?>> resolveBarcode(String code) =>
      _catalog.resolveGoodByBarcode(code);

  /// Добавить строку: в короб [boxId] (с его ячейкой) или штучно в текущую ячейку. Совпавшая
  /// грань увеличивает количество. Короб задаёт экран: на странице короба строки идут в него,
  /// в общем списке — штучно.
  ///
  /// [newBarcode] — товар опознан ранее неизвестным ШК и выбран вручную: привязка уходит
  /// обычной операцией очереди (как в «Вводе остатков», ADHOC-14). От неё строка не зависит —
  /// она ссылается на товар напрямую, поэтому строка кладётся сразу, до постановки привязки.
  Future<void> addLine({
    required Good good,
    required String date,
    required double qty,
    String? newBarcode,
    String? boxId,
  }) async {
    final box = boxId == null ? null : state.boxById(boxId);
    final cell = box == null ? state.targetCell : box.cell;
    final lines = List<ReceiptLineDraft>.from(state.lines);
    final idx = lines.indexWhere(
      (l) => l.sameGrain(
        goodId: good.id,
        date: date,
        boxId: box?.id,
        cellId: cell?.id,
      ),
    );
    if (idx >= 0) {
      lines[idx] = lines[idx].copyWith(qty: lines[idx].qty + qty);
    } else {
      lines.add(
        ReceiptLineDraft(
          good: good,
          productionDate: date,
          qty: qty,
          boxId: box?.id,
          cell: cell,
        ),
      );
    }
    emit(state.copyWith(lines: lines, failure: null));

    if (newBarcode != null) {
      // Исход не разбираем: очередь примет операцию в любом случае, а отказ по существу
      // покажет экран разбора. Строка от этого не зависит — товар выбран руками.
      await _catalog.bindBarcode(goodId: good.id, barcode: newBarcode);
    }
  }

  /// Изменить дату и количество строки (замена, не приращение). Совпала новая грань с другой
  /// строкой — количества сливаются в неё.
  void editLine(
    ReceiptLineDraft target, {
    required String date,
    required double qty,
  }) {
    final lines = List<ReceiptLineDraft>.from(state.lines);
    final idx = lines.indexOf(target);
    if (idx < 0) return;
    final dup = lines.indexWhere(
      (l) => l.sameGrain(
        goodId: target.good.id,
        date: date,
        boxId: target.boxId,
        cellId: target.cell?.id,
      ),
    );
    if (dup >= 0 && dup != idx) {
      lines[dup] = lines[dup].copyWith(qty: lines[dup].qty + qty);
      lines.removeAt(idx);
    } else {
      lines[idx] = target.copyWith(productionDate: date, qty: qty);
    }
    emit(state.copyWith(lines: lines, failure: null));
  }

  /// Удалить строку. Привязку ШК не трогаем: опознание товара остаётся верным, даже если
  /// строку количества убрали.
  void removeLine(ReceiptLineDraft target) {
    final lines = List<ReceiptLineDraft>.from(state.lines);
    if (!lines.remove(target)) return;
    emit(state.copyWith(lines: lines, failure: null));
  }

  /// Снять ошибочную привязку ШК («неверный товар»): не ушедшую — из очереди, ушедшую —
  /// отвязкой. Обе ветки идут через очередь и переживают отсутствие связи (ADHOC-14).
  Future<void> removeBarcode(String code, {required String goodId}) async {
    if (await _catalog.cancelPendingBind(code)) return;
    await _catalog.unbindBarcode(goodId: goodId, barcode: code);
  }

  //* --- штрихкоды и печать --- *//

  /// Штрихкоды товара — для печати ярлыка.
  Future<Either<Failure, List<Barcode>>> barcodesOf(String goodId) =>
      _catalog.listGoodBarcodes(goodId);

  /// Выдать товару внутренний ШК — только по сети (решение P4-09, см. репозиторий).
  Future<Either<Failure, IssuedBarcode>> issueBarcode(String goodId) =>
      _catalog.issueInternalBarcode(goodId);

  /// Напечатать ярлык короба. Возвращает текст ошибки или `null`.
  ///
  /// Неудача печати приёмку не останавливает: короб уже заведён, ярлык можно допечатать.
  Future<String?> printBoxLabel(String boxId) =>
      _print(() => _printer.printLoadUnitLabel(boxId));

  /// Напечатать товарный ярлык. Возвращает текст ошибки или `null`.
  Future<String?> printGoodLabel({
    required String barcode,
    required String goodName,
  }) => _print(
    () => _printer.printGoodLabel(barcode: barcode, goodName: goodName),
  );

  /// Общая обвязка печати: ошибку принтера переводим в текст для человека.
  Future<String?> _print(Future<void> Function() job) async {
    try {
      await job();
      return null;
    } on PrinterFailure catch (e) {
      return e.userMessage;
    } catch (e) {
      return e.toString();
    }
  }

  //* --- завершение --- *//

  /// Завершить приёмку: поставить её в очередь одной операцией и попробовать отправить.
  ///
  /// Черновик стирается в любом исходе, кроме неудачной постановки: с этого момента копия
  /// приёмки живёт в очереди операций. Связи нет — она уйдёт сама; отказ сервера — её разбирают
  /// на экране несинхронизированного.
  Future<void> submit() async {
    // Без документа поставщика сервер приёмку не проведёт (ADHOC-23); экран спрашивает его
    // до вызова, здесь — страховка от вызова в обход экрана.
    if (!state.canSubmit || state.doc == null) return;
    emit(state.copyWith(busy: true, failure: null));
    final res = await _repo.submit(_payload(state));
    final s = state.copyWith(busy: false);
    emit(
      res.fold(
        (f) => f is RejectedFailure
            ? s.copyWith(
                outcome: ReceiptOutcome.rejected,
                rejectReason: f.reason,
              )
            : s.copyWith(outcome: ReceiptOutcome.queued),
        (_) => s.copyWith(outcome: ReceiptOutcome.posted),
      ),
    );
  }

  /// Тело операции `receipt_submit`.
  ///
  /// Короба едут только те, в которых есть строки: пустой короб на сервере был бы ГЕ без
  /// состава, место хранения которой ничем не подтверждено. Ячейка строки пуста — сервер
  /// подставит ячейку по умолчанию; решает он, а не терминал, чтобы умолчание жило в одном месте.
  Map<String, dynamic> _payload(ReceiptState s) {
    final usedBoxes = s.lines.map((l) => l.boxId).nonNulls.toSet();
    return {
      'receipt_id': s.receiptId,
      'warehouse_id': s.defaultCell!.warehouseId,
      if (s.supplier != null) 'supplier_id': s.supplier!.id,
      'doc_number': s.doc!.number,
      'doc_date': s.doc!.transportDate,
      'load_units': [
        for (final b in s.boxes)
          if (usedBoxes.contains(b.id)) {'id': b.id, 'kind': 'box'},
      ],
      'lines': [
        for (final l in s.lines)
          {
            'good_id': l.good.id,
            // В UI дата с точками (дд.мм.гггг), транспорт — DD-MM-YYYY, как у ввода остатков.
            'production_date': l.productionDate.replaceAll('.', '-'),
            'qty': l.qty,
            if (l.cell != null) 'cell_id': l.cell!.id,
            if (l.boxId != null) 'load_unit_id': l.boxId,
          },
      ],
    };
  }

  /// Сбросить ошибку (после показа пользователю).
  void clearFailure() => emit(state.copyWith(failure: null));
}

/// Маркер отказа «у склада нет ячейки по умолчанию» — экран переводит его в текст.
const String kNoDefaultCell = 'no_default_cell';
