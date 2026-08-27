import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:injectable/injectable.dart';

import '../../../../core/error/failure.dart';
import '../../../stock/data/catalog_models.dart';
import '../../data/stock_entry_repository.dart';

part 'stock_entry_cubit.freezed.dart';

/// Максимум операций отмены (буфер текущей ячейки).
const int kUndoDepth = 10;

/// Черновик строки ввода: товар + партия (дата выпуска) + количество. Грань — (good, productionDate):
/// один товар может лежать в ячейке разными партиями. ШК на строке НЕ хранится: привязка
/// `ШК → товар` — факт справочника (уровень товара), живёт отдельно в [StockEntryState.barcodes].
@freezed
abstract class EntryLineDraft with _$EntryLineDraft {
  const factory EntryLineDraft({
    required Good good,
    required String productionDate, // дд.мм.гггг (в UI); в API конвертируется в DD-MM-YYYY
    required double qty,
  }) = _EntryLineDraft;
}

/// Привязка `ШК → товар`, собранная за проход. Символика — как отдал сканер (сейчас пусто).
/// Множитель упаковки НЕ храним: ШК только идентифицирует товар, количество оператор вводит
/// в базовой единице руками (вариант A). У товара может быть сколько угодно ШК (штука, короб…).
@freezed
abstract class BarcodeBinding with _$BarcodeBinding {
  const factory BarcodeBinding({
    required Good good,
    @Default('') String symbology,
  }) = _BarcodeBinding;
}

/// Снимок буфера ячейки для Undo: строки + копилка ШК на момент до операции. ШК включён в снимок,
/// чтобы отмена откатывала и ошибочную привязку, а не только количество.
@freezed
abstract class BufferSnapshot with _$BufferSnapshot {
  const factory BufferSnapshot({
    required List<EntryLineDraft> lines,
    required Map<String, BarcodeBinding> barcodes,
  }) = _BufferSnapshot;
}

/// Пройденная (завершённая) ячейка со своими строками — держится локально до финала.
@freezed
abstract class CommittedCell with _$CommittedCell {
  const factory CommittedCell({
    required Cell cell,
    required List<EntryLineDraft> lines,
  }) = _CommittedCell;
}

/// Состояние экрана-потока ввода остатков. Вариант A: всё копится в памяти ТСД; на сервер уходит
/// одним махом при «Завершить ввод» (старт сессии → checkpoint каждой ячейки → финал). Пройденные
/// ячейки редактируемы до финала.
@freezed
abstract class StockEntryState with _$StockEntryState {
  const factory StockEntryState({
    Cell? cell, // текущая редактируемая ячейка (null — экран выбора ячейки)
    @Default(<EntryLineDraft>[]) List<EntryLineDraft> lines, // буфер текущей ячейки
    @Default(<BufferSnapshot>[]) List<BufferSnapshot> undoStack,
    @Default(<CommittedCell>[]) List<CommittedCell> committedCells, // пройденные ячейки (локально)
    // Копилка привязок ШК → товар за весь проход (ключ — строка ШК). Собирается ручными привязками,
    // не зависит от строк остатка; на финале целиком уходит в БД (new_barcodes, аддитивно).
    @Default(<String, BarcodeBinding>{}) Map<String, BarcodeBinding> barcodes,
    String? sessionId, // серверная сессия — создаётся только на финале
    @Default(false) bool busy, // сетевая операция финала
    @Default(false) bool finished, // финал выполнен
    @Default(0) int written, // записано строк в stock (после финала)
    Failure? failure,
  }) = _StockEntryState;

  const StockEntryState._();

  /// Можно завершить ввод: есть пройденные ячейки, текущая не в работе, не идёт сетевой финал.
  bool get canFinishSession => committedCells.isNotEmpty && cell == null && !busy;
}

/// Cubit ввода остатков (вариант A): буфер ячейки, Undo, список пройденных ячеек (локально),
/// финал одним пакетом. Фабрика (свой на экран).
@injectable
class StockEntryCubit extends Cubit<StockEntryState> {
  StockEntryCubit(this._repo) : super(const StockEntryState());

  final StockEntryRepository _repo;

  /// Выбрать ячейку для работы. Если ячейка уже пройдена — открываем её на редактирование:
  /// забираем строки в буфер и убираем из списка пройденных (вернётся при «Завершить ячейку»).
  void selectCell(Cell cell) {
    final idx = state.committedCells.indexWhere((c) => c.cell.id == cell.id);
    if (idx >= 0) {
      final existing = state.committedCells[idx];
      final committed = List<CommittedCell>.from(state.committedCells)..removeAt(idx);
      emit(state.copyWith(
        cell: cell,
        lines: existing.lines,
        undoStack: const [],
        committedCells: committed,
        failure: null,
      ));
    } else {
      emit(state.copyWith(cell: cell, lines: const [], undoStack: const [], failure: null));
    }
  }

  /// Сменить целевую ячейку текущего буфера, СОХРАНИВ набранные строки (ошиблись ячейкой, товары
  /// верны — перецеливаем, не пересканируя). Если новая ячейка уже пройдена — сливаем её строки в
  /// буфер по грани (товар, дата) и убираем из пройденных: иначе на финале два чекпоинта на одну
  /// ячейку затрут друг друга по SET-грани `UNIQUE(session,cell,good,date)`. Undo сбрасываем — это
  /// структурная смена, а не правка буфера.
  void changeCell(Cell newCell) {
    final current = state.cell;
    if (current == null || current.id == newCell.id) return;
    var lines = state.lines;
    var committed = state.committedCells;
    final idx = committed.indexWhere((c) => c.cell.id == newCell.id);
    if (idx >= 0) {
      lines = _mergeLines(state.lines, committed[idx].lines);
      committed = List<CommittedCell>.from(committed)..removeAt(idx);
    }
    emit(state.copyWith(
      cell: newCell,
      lines: lines,
      committedCells: committed,
      undoStack: const [],
      failure: null,
    ));
  }

  /// Слить строки `add` в `base` по грани (товар, дата): совпало → сумма qty; иначе — новая строка.
  List<EntryLineDraft> _mergeLines(List<EntryLineDraft> base, List<EntryLineDraft> add) {
    final out = List<EntryLineDraft>.from(base);
    for (final l in add) {
      final i = out.indexWhere(
          (x) => x.good.id == l.good.id && x.productionDate == l.productionDate);
      if (i >= 0) {
        out[i] = out[i].copyWith(qty: out[i].qty + l.qty);
      } else {
        out.add(l);
      }
    }
    return out;
  }

  /// Товар по ШК среди привязок, собранных за проход (копилка [StockEntryState.barcodes]). Чтобы
  /// повторный скан любого уже привязанного ШK узнавался локально, а не бил в 404 (данные ещё не на
  /// сервере) — независимо от того, сколько ШК на товар и в какой ячейке его привязали.
  Good? localGoodForBarcode(String code) => state.barcodes[code]?.good;

  /// Резолв товара по ШК на сервере. null = ШК не привязан (UI откроет привязку). Ошибку кладём в state.
  Future<Good?> resolveBarcode(String code) async {
    final res = await _repo.resolveGoodByBarcode(code);
    return res.fold((f) {
      emit(state.copyWith(failure: f));
      return null;
    }, (good) => good);
  }

  /// Добавить/накопить строку. Грань (good, date): та же дата → +qty; другая дата → новая строка.
  /// [newBarcode] — если товар был опознан ранее НЕизвестным ШК (ручная привязка): кладём привязку
  /// в копилку [StockEntryState.barcodes] (уедет в БД на финале). Перед изменением — снимок в Undo.
  void addLine({
    required Good good,
    required String date,
    required double qty,
    String? newBarcode,
    String? symbology,
  }) {
    final snapLines = List<EntryLineDraft>.from(state.lines);
    final snapBarcodes = Map<String, BarcodeBinding>.from(state.barcodes);

    final barcodes = Map<String, BarcodeBinding>.from(state.barcodes);
    if (newBarcode != null && !barcodes.containsKey(newBarcode)) {
      barcodes[newBarcode] = BarcodeBinding(good: good, symbology: symbology ?? '');
    }

    final lines = List<EntryLineDraft>.from(state.lines);
    final idx = lines.indexWhere((l) => l.good.id == good.id && l.productionDate == date);
    if (idx >= 0) {
      lines[idx] = lines[idx].copyWith(qty: lines[idx].qty + qty);
    } else {
      lines.add(EntryLineDraft(good: good, productionDate: date, qty: qty));
    }
    _commit(snapLines, snapBarcodes, lines, barcodes);
  }

  /// Удалить строку из буфера (по грани good+partiya). Кладёт снимок в Undo. Привязку ШК НЕ трогаем:
  /// идентификация товара остаётся валидной, даже если строку количества убрали.
  void removeLine(EntryLineDraft line) {
    final lines = state.lines
        .where((l) => !(l.good.id == line.good.id && l.productionDate == line.productionDate))
        .toList();
    if (lines.length == state.lines.length) return; // не нашли — ничего не делаем
    _commit(List<EntryLineDraft>.from(state.lines), state.barcodes, lines, state.barcodes);
  }

  /// Отредактировать строку: новые дата и количество (замена, не приращение). Если новая грань
  /// (тот же товар, новая дата) совпала с другой строкой — сливаем количества в неё. Кладёт снимок в Undo.
  void editLine(EntryLineDraft target, {required String date, required double qty}) {
    final lines = List<EntryLineDraft>.from(state.lines);
    final idx = lines.indexWhere(
        (l) => l.good.id == target.good.id && l.productionDate == target.productionDate);
    if (idx < 0) return;

    final edited = lines[idx];
    final dupIdx = lines.indexWhere((l) => l.good.id == edited.good.id && l.productionDate == date);
    if (dupIdx >= 0 && dupIdx != idx) {
      // Новая дата совпала с уже существующей партией того же товара → слить количества.
      lines[dupIdx] = lines[dupIdx].copyWith(qty: lines[dupIdx].qty + qty);
      lines.removeAt(idx);
    } else {
      lines[idx] = edited.copyWith(productionDate: date, qty: qty);
    }
    _commit(List<EntryLineDraft>.from(state.lines), state.barcodes, lines, state.barcodes);
  }

  /// Применить новый буфер, положив предыдущий снимок (строки + копилка ШК) в стек Undo (глубина
  /// [kUndoDepth]).
  void _commit(
    List<EntryLineDraft> snapLines,
    Map<String, BarcodeBinding> snapBarcodes,
    List<EntryLineDraft> newLines,
    Map<String, BarcodeBinding> newBarcodes,
  ) {
    final undo = [...state.undoStack, BufferSnapshot(lines: snapLines, barcodes: snapBarcodes)];
    final capped = undo.length > kUndoDepth ? undo.sublist(undo.length - kUndoDepth) : undo;
    emit(state.copyWith(lines: newLines, barcodes: newBarcodes, undoStack: capped, failure: null));
  }

  /// Убрать ошибочную привязку ШК из копилки прохода (P-FS-12). Применимо только к привязке,
  /// сделанной в ЭТОЙ сессии (на сервере её ещё нет) — серверную снимает экран через DELETE.
  /// Кладёт снимок в Undo (откат вернёт привязку). Нет такого ШК в копилке — ничего не делаем.
  void removeLocalBarcode(String code) {
    if (!state.barcodes.containsKey(code)) return;
    final snapBarcodes = Map<String, BarcodeBinding>.from(state.barcodes);
    final barcodes = Map<String, BarcodeBinding>.from(state.barcodes)..remove(code);
    _commit(List<EntryLineDraft>.from(state.lines), snapBarcodes, state.lines, barcodes);
  }

  /// Отменить последнюю операцию буфера (восстановить строки И копилку ШК из предыдущего снимка).
  void undo() {
    if (state.undoStack.isEmpty) return;
    final prev = state.undoStack.last;
    emit(state.copyWith(
      lines: prev.lines,
      barcodes: prev.barcodes,
      undoStack: state.undoStack.sublist(0, state.undoStack.length - 1),
    ));
  }

  /// Завершить ячейку: положить её в список пройденных (локально, без сети). Пустую (без строк)
  /// не добавляем. Затем — экран выбора ячейки.
  void finishCell() {
    final cell = state.cell;
    if (cell == null) return;
    final committed = List<CommittedCell>.from(state.committedCells);
    if (state.lines.isNotEmpty) {
      committed.add(CommittedCell(cell: cell, lines: state.lines));
    }
    emit(state.copyWith(
      cell: null,
      lines: const [],
      undoStack: const [],
      committedCells: committed,
      failure: null,
    ));
  }

  /// Удалить пройденную ячейку из списка (ошибочный просчёт).
  void removeCommittedCell(String cellId) {
    final committed = state.committedCells.where((c) => c.cell.id != cellId).toList();
    if (committed.length == state.committedCells.length) return;
    emit(state.copyWith(committedCells: committed));
  }

  /// Завершить ввод остатков: старт сессии → checkpoint каждой пройденной ячейки → финал. Всё
  /// отправляется на сервер здесь. При ошибке — прерываемся; sessionId сохраняем, чтобы ретрай
  /// переиспользовал ту же сессию (checkpoint идемпотентен по грани, лишних сессий не плодим).
  Future<void> finishSession() async {
    if (state.cell != null || state.committedCells.isEmpty || state.busy) return;
    emit(state.copyWith(busy: true, failure: null));

    var sid = state.sessionId;
    if (sid == null) {
      final startRes = await _repo.startSession(state.committedCells.first.cell.warehouseId);
      final ok = startRes.fold((f) {
        emit(state.copyWith(busy: false, failure: f));
        return false;
      }, (id) {
        sid = id;
        return true;
      });
      if (!ok) return;
      emit(state.copyWith(sessionId: sid)); // сохранить, чтобы ретрай не плодил сессии
    }

    // Привязки ШК — общие на весь проход, не на ячейку. Отправляем всю копилку с ПЕРВЫМ checkpoint
    // (bind на бэке идемпотентен; при ретрае цикл снова стартует с первой ячейки → пере-отправка).
    final allBarcodes = _barcodesPayload();
    for (var i = 0; i < state.committedCells.length; i++) {
      final cc = state.committedCells[i];
      final res = await _repo.checkpoint(
        sessionId: sid!,
        cellId: cc.cell.id,
        lines: _linesPayload(cc.lines),
        newBarcodes: i == 0 ? allBarcodes : const [],
      );
      final failed = res.fold((f) {
        emit(state.copyWith(busy: false, failure: f));
        return true;
      }, (_) => false);
      if (failed) return;
    }

    final finRes = await _repo.finalize(sid!);
    finRes.fold(
      (f) => emit(state.copyWith(busy: false, failure: f)),
      (written) => emit(state.copyWith(busy: false, finished: true, written: written, failure: null)),
    );
  }

  /// Строки ячейки → payload API. Дата в UI хранится с точками (дд.мм.гггг); API ждёт DD-MM-YYYY.
  List<Map<String, dynamic>> _linesPayload(List<EntryLineDraft> lines) => lines
      .map((l) => <String, dynamic>{
            'good_id': l.good.id,
            'production_date': l.productionDate.replaceAll('.', '-'),
            'qty': l.qty,
          })
      .toList();

  /// Вся копилка привязок ШК за проход → payload API (`[{good_id, barcode, symbology}]`). Ключ карты
  /// — сам ШК, так что дубли исключены по построению.
  List<Map<String, dynamic>> _barcodesPayload() => state.barcodes.entries
      .map((e) => <String, dynamic>{
            'good_id': e.value.good.id,
            'barcode': e.key,
            'symbology': e.value.symbology,
          })
      .toList();

  /// Сбросить ошибку (после показа пользователю).
  void clearFailure() => emit(state.copyWith(failure: null));
}
