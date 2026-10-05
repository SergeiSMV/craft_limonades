import 'package:either_dart/either.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:injectable/injectable.dart';

import '../../../../core/error/failure.dart';
import '../../../../core/load_unit/load_unit_id_generator.dart';
import '../../../../core/printer/load_unit_label.dart';
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
/// в текущий короб или штучно, в текущую ячейку → … → «Завершить приёмку». Всё копится на
/// терминале и уходит на сервер одной операцией очереди.
@freezed
abstract class ReceiptState with _$ReceiptState {
  const factory ReceiptState({
    /// Поставщик выбран (или выбрано «без поставщика») — приёмка начата.
    @Default(false) bool started,

    /// Идентификатор документа. Выдаёт терминал: приёмку начинают и без связи.
    String? receiptId,

    /// `null` при начатой приёмке — без поставщика (внутреннее поступление, возврат).
    Supplier? supplier,

    /// Ячейка приёмки по умолчанию («С-Н-П»). Из неё же берётся склад документа.
    Cell? defaultCell,

    /// Куда ложатся новые строки и новые короба; `null` — в ячейку по умолчанию.
    Cell? targetCell,
    @Default(<ReceiptBox>[]) List<ReceiptBox> boxes,

    /// Короб, в который кладут сейчас; `null` — товар принимают штучно.
    String? currentBoxId,
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

  /// Короб, в который кладут сейчас.
  ReceiptBox? get currentBox =>
      boxes.where((b) => b.id == currentBoxId).firstOrNull;

  /// Сколько строк лежит в коробе.
  int linesInBox(String boxId) => lines.where((l) => l.boxId == boxId).length;

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
    'default_cell': s.defaultCell?.toJson(),
    'target_cell': s.targetCell?.toJson(),
    'boxes': s.boxes.map((b) => b.toJson()).toList(),
    'current_box_id': s.currentBoxId,
    'lines': s.lines.map((l) => l.toJson()).toList(),
  };

  /// Состояние из слепка.
  ReceiptState _stateFromDraft(Map<String, dynamic> d) {
    Map<String, dynamic>? map(String key) => d[key] as Map<String, dynamic>?;
    List<dynamic> list(String key) => d[key] as List<dynamic>? ?? const [];
    final supplier = map('supplier');
    final defaultCell = map('default_cell');
    final targetCell = map('target_cell');
    return ReceiptState(
      started: true,
      receiptId: d['receipt_id'] as String?,
      supplier: supplier == null ? null : Supplier.fromJson(supplier),
      defaultCell: defaultCell == null ? null : Cell.fromJson(defaultCell),
      targetCell: targetCell == null ? null : Cell.fromJson(targetCell),
      boxes: list(
        'boxes',
      ).map((e) => ReceiptBox.fromJson(e as Map<String, dynamic>)).toList(),
      currentBoxId: d['current_box_id'] as String?,
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

  /// Начать приёмку от поставщика (`null` — без поставщика).
  ///
  /// Ячейка по умолчанию нужна сразу: из неё берётся склад документа, и без неё приёмку
  /// не оприходовать. Её отсутствие — незавершённое развёртывание, чинится админом,
  /// поэтому приёмку не начинаем вовсе, а не обнаруживаем это на финале.
  Future<void> start(Supplier? supplier) async {
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
        defaultCell: cell,
      ),
    );
  }

  //* --- ячейка и короба --- *//

  /// Сменить ячейку для новых строк и новых коробов. Дефолтная ячейка сбрасывает выбор.
  ///
  /// Уже собранные короба своей ячейки не меняют — она закреплена при создании (см.
  /// [ReceiptBox]). Текущий короб при этом закрывается: иначе следующая строка легла бы
  /// в короб с другой ячейкой, чем та, что кладовщик только что отсканировал.
  void setTargetCell(Cell cell) {
    emit(
      state.copyWith(
        targetCell: cell.isDefault ? null : cell,
        currentBoxId: null,
        failure: null,
      ),
    );
  }

  /// Новый короб: выдаёт идентификатор, закрепляет за коробом текущую ячейку и делает его
  /// текущим. Возвращает идентификатор — по нему печатают ярлык.
  ///
  /// Короб создаётся на терминале, без сети: ярлык печатается и клеится сразу, а на сервере
  /// ГЕ появится вместе с приёмкой.
  String newBox() {
    final box = ReceiptBox(id: _ids.newId(), cell: state.targetCell);
    emit(
      state.copyWith(
        boxes: [...state.boxes, box],
        currentBoxId: box.id,
        failure: null,
      ),
    );
    return box.id;
  }

  /// Продолжить класть в короб этой приёмки.
  void selectBox(String boxId) {
    if (!state.boxes.any((b) => b.id == boxId)) return;
    emit(state.copyWith(currentBoxId: boxId, failure: null));
  }

  /// Закрыть текущий короб: дальше товар принимается штучно.
  void closeBox() => emit(state.copyWith(currentBoxId: null));

  /// Отсканирован ярлык короба. `true` — короб из этой приёмки, он стал текущим.
  ///
  /// Короб из другой приёмки сюда не берём: он уже где-то лежит со своим составом, и класть
  /// в него на приёмке значит переместить его, а перемещение — отдельная операция (P6).
  bool selectScannedBox(String loadUnitId) {
    final id = loadUnitId.toLowerCase();
    if (!state.boxes.any((b) => b.id == id)) return false;
    selectBox(id);
    return true;
  }

  /// Короба приёмки, чей короткий код совпадает с набранным (ярлык затёрт, QR не читается).
  ///
  /// Сравнение через [LoadUnitLabel.normalizeShortCode]: на ярлыке код разбит пробелом,
  /// и человек набирает его так, как видит. Совпадение по началу — чтобы список сужался
  /// по мере набора; полный код из восьми знаков почти всегда оставит один короб.
  List<ReceiptBox> boxesByShortCode(String input) {
    final needle = LoadUnitLabel.normalizeShortCode(input);
    if (needle.isEmpty) return state.boxes;
    return state.boxes
        .where(
          (b) =>
              LoadUnitLabel.normalizeShortCode(b.shortCode).startsWith(needle),
        )
        .toList();
  }

  //* --- строки --- *//

  /// Резолв товара по ШК — через общий кэш-first репозиторий справочников. Исход целиком:
  /// «ШК не привязан» и «проверить не удалось» — разные вещи (ADHOC-06).
  Future<Either<Failure, Good?>> resolveBarcode(String code) =>
      _catalog.resolveGoodByBarcode(code);

  /// Добавить строку: в текущий короб (с его ячейкой) или штучно в текущую ячейку. Совпавшая
  /// грань увеличивает количество.
  ///
  /// [newBarcode] — товар опознан ранее неизвестным ШК и выбран вручную: привязка уходит
  /// обычной операцией очереди (как в «Вводе остатков», ADHOC-14). От неё строка не зависит —
  /// она ссылается на товар напрямую, поэтому строка кладётся сразу, до постановки привязки.
  Future<void> addLine({
    required Good good,
    required String date,
    required double qty,
    String? newBarcode,
  }) async {
    final box = state.currentBox;
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
      return e.message;
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
    if (!state.canSubmit) return;
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
