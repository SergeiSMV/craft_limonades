import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:injectable/injectable.dart';

import '../../../core/error/failure.dart';
import '../../stock/data/catalog_models.dart';
import '../data/stock_entry_repository.dart';

part 'stock_entry_cubit.freezed.dart';

/// Максимум операций отмены (буфер текущей ячейки).
const int kUndoDepth = 10;

/// Черновик строки ввода: товар + партия (дата выпуска) + количество. Грань — (good, productionDate):
/// один товар может лежать в ячейке разными партиями. [bindBarcode] — если строкой попутно
/// привязывается новый ШК (уедет на сервер как new_barcode при финале).
@freezed
abstract class EntryLineDraft with _$EntryLineDraft {
  const factory EntryLineDraft({
    required Good good,
    required String productionDate, // дд.мм.гггг (в UI); в API конвертируется в DD-MM-YYYY
    required double qty,
    String? bindBarcode,
    String? bindSymbology,
  }) = _EntryLineDraft;
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
    @Default(<List<EntryLineDraft>>[]) List<List<EntryLineDraft>> undoStack,
    @Default(<CommittedCell>[]) List<CommittedCell> committedCells, // пройденные ячейки (локально)
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

  /// Товар по ШК среди ОТЛОЖЕННЫХ привязок (текущий буфер + все пройденные ячейки). Чтобы повторный
  /// скан только что привязанного ШК узнавался локально, а не бил в 404 (данные ещё не на сервере).
  Good? localGoodForBarcode(String code) {
    for (final l in state.lines) {
      if (l.bindBarcode == code) return l.good;
    }
    for (final cc in state.committedCells) {
      for (final l in cc.lines) {
        if (l.bindBarcode == code) return l.good;
      }
    }
    return null;
  }

  /// Резолв товара по ШК на сервере. null = ШК не привязан (UI откроет привязку). Ошибку кладём в state.
  Future<Good?> resolveBarcode(String code) async {
    final res = await _repo.resolveGoodByBarcode(code);
    return res.fold((f) {
      emit(state.copyWith(failure: f));
      return null;
    }, (good) => good);
  }

  /// Добавить/накопить строку. Грань (good, date): та же дата → +qty; другая дата → новая строка.
  /// Перед изменением кладём снимок буфера в стек отмены (глубина [kUndoDepth]).
  void addLine({
    required Good good,
    required String date,
    required double qty,
    String? bindBarcode,
    String? bindSymbology,
  }) {
    final snapshot = List<EntryLineDraft>.from(state.lines);
    final lines = List<EntryLineDraft>.from(state.lines);
    final idx = lines.indexWhere((l) => l.good.id == good.id && l.productionDate == date);
    if (idx >= 0) {
      final ex = lines[idx];
      lines[idx] = ex.copyWith(
        qty: ex.qty + qty,
        bindBarcode: ex.bindBarcode ?? bindBarcode,
        bindSymbology: ex.bindSymbology ?? bindSymbology,
      );
    } else {
      lines.add(EntryLineDraft(
        good: good,
        productionDate: date,
        qty: qty,
        bindBarcode: bindBarcode,
        bindSymbology: bindSymbology,
      ));
    }
    _commitLines(snapshot, lines);
  }

  /// Удалить строку из буфера (по грани good+partiya). Кладёт снимок в Undo.
  void removeLine(EntryLineDraft line) {
    final snapshot = List<EntryLineDraft>.from(state.lines);
    final lines = state.lines
        .where((l) => !(l.good.id == line.good.id && l.productionDate == line.productionDate))
        .toList();
    if (lines.length == state.lines.length) return; // не нашли — ничего не делаем
    _commitLines(snapshot, lines);
  }

  /// Отредактировать строку: новые дата и количество (замена, не приращение). Если новая грань
  /// (тот же товар, новая дата) совпала с другой строкой — сливаем количества в неё. Кладёт снимок в Undo.
  void editLine(EntryLineDraft target, {required String date, required double qty}) {
    final snapshot = List<EntryLineDraft>.from(state.lines);
    final lines = List<EntryLineDraft>.from(state.lines);
    final idx = lines.indexWhere(
        (l) => l.good.id == target.good.id && l.productionDate == target.productionDate);
    if (idx < 0) return;

    final edited = lines[idx];
    final dupIdx = lines.indexWhere((l) => l.good.id == edited.good.id && l.productionDate == date);
    if (dupIdx >= 0 && dupIdx != idx) {
      // Новая дата совпала с уже существующей партией того же товара → слить количества.
      final dup = lines[dupIdx];
      lines[dupIdx] = dup.copyWith(
        qty: dup.qty + qty,
        bindBarcode: dup.bindBarcode ?? edited.bindBarcode,
        bindSymbology: dup.bindSymbology ?? edited.bindSymbology,
      );
      lines.removeAt(idx);
    } else {
      lines[idx] = edited.copyWith(productionDate: date, qty: qty);
    }
    _commitLines(snapshot, lines);
  }

  /// Применить новый буфер, положив предыдущий снимок в стек Undo (глубина [kUndoDepth]).
  void _commitLines(List<EntryLineDraft> snapshot, List<EntryLineDraft> newLines) {
    final undo = [...state.undoStack, snapshot];
    final capped = undo.length > kUndoDepth ? undo.sublist(undo.length - kUndoDepth) : undo;
    emit(state.copyWith(lines: newLines, undoStack: capped, failure: null));
  }

  /// Отменить последнюю операцию буфера (восстановить предыдущий снимок).
  void undo() {
    if (state.undoStack.isEmpty) return;
    final prev = state.undoStack.last;
    emit(state.copyWith(
      lines: prev,
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

    for (final cc in state.committedCells) {
      final res = await _repo.checkpoint(
        sessionId: sid!,
        cellId: cc.cell.id,
        lines: _linesPayload(cc.lines),
        newBarcodes: _barcodesPayload(cc.lines),
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

  /// Уникальные привязки ШК из строк ячейки → payload API.
  List<Map<String, dynamic>> _barcodesPayload(List<EntryLineDraft> lines) {
    final seen = <String>{};
    final out = <Map<String, dynamic>>[];
    for (final l in lines) {
      final bc = l.bindBarcode;
      if (bc != null && seen.add(bc)) {
        out.add({'good_id': l.good.id, 'barcode': bc, 'symbology': l.bindSymbology ?? ''});
      }
    }
    return out;
  }

  /// Сбросить ошибку (после показа пользователю).
  void clearFailure() => emit(state.copyWith(failure: null));
}
