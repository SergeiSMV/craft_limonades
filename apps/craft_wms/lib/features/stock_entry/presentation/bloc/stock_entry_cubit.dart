import 'package:either_dart/either.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:injectable/injectable.dart';

import '../../../../core/error/failure.dart';
import '../../../stock/data/catalog_models.dart';
import '../../data/entry_draft_store.dart';
import '../../../stock/data/catalog_repository.dart';
import '../../data/stock_entry_repository.dart';

part 'stock_entry_cubit.freezed.dart';
part 'stock_entry_cubit.g.dart';

/// Максимум операций отмены (буфер текущей ячейки).
const int kUndoDepth = 10;

/// Черновик строки ввода: товар + партия (дата выпуска) + количество. Грань — (good, productionDate):
/// один товар может лежать в ячейке разными партиями. ШК на строке НЕ хранится: привязка
/// `ШК → товар` — факт справочника (уровень товара), живёт отдельно в [StockEntryState.barcodes].
@freezed
abstract class EntryLineDraft with _$EntryLineDraft {
  const factory EntryLineDraft({
    required Good good,
    required String
    productionDate, // дд.мм.гггг (в UI); в API конвертируется в DD-MM-YYYY
    required double qty,
  }) = _EntryLineDraft;

  /// Разбор из слепка незавершённого прохода (P2-03).
  factory EntryLineDraft.fromJson(Map<String, dynamic> json) =>
      _$EntryLineDraftFromJson(json);
}

/// Снимок буфера ячейки для Undo: строки + копилка ШК на момент до операции. ШК включён в снимок,
/// чтобы отмена откатывала и ошибочную привязку, а не только количество.
@freezed
abstract class BufferSnapshot with _$BufferSnapshot {
  const factory BufferSnapshot({
    required List<EntryLineDraft> lines,

    /// ШК, привязанный на этом шаге, если он был. Отмена шага пытается снять эту привязку,
    /// пока та не ушла на сервер (ADHOC-14). Раньше здесь лежала вся копилка прохода —
    /// с переходом привязок в очередь хранить её в снимке стало нечего.
    String? addedBarcode,
  }) = _BufferSnapshot;
}

/// Пройденная (завершённая) ячейка со своими строками — держится локально до финала.
@freezed
abstract class CommittedCell with _$CommittedCell {
  const factory CommittedCell({
    required Cell cell,
    required List<EntryLineDraft> lines,
  }) = _CommittedCell;

  /// Разбор из слепка незавершённого прохода (P2-03).
  factory CommittedCell.fromJson(Map<String, dynamic> json) =>
      _$CommittedCellFromJson(json);
}

/// Состояние экрана-потока ввода остатков. Вариант A: всё копится в памяти ТСД; на сервер уходит
/// одним махом при «Завершить ввод» (старт сессии → checkpoint каждой ячейки → финал). Пройденные
/// ячейки редактируемы до финала.
@freezed
abstract class StockEntryState with _$StockEntryState {
  const factory StockEntryState({
    Cell? cell, // текущая редактируемая ячейка (null — экран выбора ячейки)
    @Default(<EntryLineDraft>[])
    List<EntryLineDraft> lines, // буфер текущей ячейки
    @Default(<BufferSnapshot>[]) List<BufferSnapshot> undoStack,
    @Default(<CommittedCell>[])
    List<CommittedCell> committedCells, // пройденные ячейки (локально)
    String? sessionId, // серверная сессия — создаётся только на финале
    @Default(false) bool busy, // сетевая операция финала
    @Default(false) bool finished, // финал выполнен
    @Default(0) int written, // записано строк в stock (после финала)
    Failure? failure,
  }) = _StockEntryState;

  const StockEntryState._();

  /// Можно завершить ввод: есть пройденные ячейки, текущая не в работе, не идёт сетевой финал.
  bool get canFinishSession =>
      committedCells.isNotEmpty && cell == null && !busy;
}

/// Cubit ввода остатков (вариант A): буфер ячейки, Undo, список пройденных ячеек (локально),
/// финал одним пакетом. Фабрика (свой на экран).
@injectable
class StockEntryCubit extends Cubit<StockEntryState> {
  StockEntryCubit(this._repo, this._catalog, this._drafts)
    : super(const StockEntryState());

  final CatalogRepository _catalog;
  final EntryDraftStore _drafts;

  /// Очередь записей слепка. Слепок снимается синхронно в момент [emit], а пишется по цепочке:
  /// два быстрых изменения подряд иначе ушли бы в базу параллельно, и последней могла бы лечь
  /// более ранняя версия прохода.
  Future<void> _writes = Future<void>.value();

  /// Восстановить незавершённый проход. Зовётся один раз при открытии экрана.
  ///
  /// Слепок пишется на каждое изменение буфера, поэтому «восстановить» означает вернуть
  /// состояние на момент последнего действия кладовщика, а не на момент открытия экрана.
  Future<void> restore() async {
    final draft = await _drafts.load();
    if (draft == null) return;
    emit(_stateFromDraft(draft));
  }

  /// Слепок durable-части состояния.
  ///
  /// Что НЕ входит: [StockEntryState.undoStack] — Undo служит текущему действию, переживать
  /// перезапуск ему незачем; [StockEntryState.busy] и [StockEntryState.failure] — они описывают
  /// сетевой вызов, которого после перезапуска уже нет.
  ///
  /// [StockEntryState.sessionId] входит: если процесс умер посреди финала, сессия на сервере
  /// уже создана, и повторный финал без её идентификатора завёл бы вторую.
  Map<String, dynamic> _draftJson(StockEntryState s) => {
    'cell': s.cell?.toJson(),
    'lines': s.lines.map((l) => l.toJson()).toList(),
    'committed_cells': s.committedCells.map((c) => c.toJson()).toList(),
    'session_id': s.sessionId,
  };

  /// Состояние из слепка.
  StockEntryState _stateFromDraft(Map<String, dynamic> draft) {
    final cell = draft['cell'] as Map<String, dynamic>?;
    return StockEntryState(
      cell: cell == null ? null : Cell.fromJson(cell),
      lines: (draft['lines'] as List<dynamic>? ?? const [])
          .map((e) => EntryLineDraft.fromJson(e as Map<String, dynamic>))
          .toList(),
      committedCells: (draft['committed_cells'] as List<dynamic>? ?? const [])
          .map((e) => CommittedCell.fromJson(e as Map<String, dynamic>))
          .toList(),
      sessionId: draft['session_id'] as String?,
    );
  }

  /// Есть ли что сохранять: пустой проход слепка не заслуживает.
  bool _hasDraft(StockEntryState s) =>
      s.cell != null || s.lines.isNotEmpty || s.committedCells.isNotEmpty;

  /// Сохранение слепка повешено на [emit], а не расставлено по методам-мутациям намеренно:
  /// изменяющих буфер методов семь (выбор и смена ячейки, три правки строк, отмена,
  /// завершение ячейки, удаление пройденной), и восьмой, добавленный позже, про сохранение
  /// забыл бы. Один перехват на все изменения забыть невозможно.
  @override
  void emit(StockEntryState state) {
    super.emit(state);
    // Финал прошёл — проход больше не нужен; пустой проход тоже не храним.
    final done = state.finished || !_hasDraft(state);
    final snapshot = done ? null : _draftJson(state);
    _writes = _writes
        .then(
          (_) => snapshot == null ? _drafts.clear() : _drafts.save(snapshot),
        )
        // Сбой записи слепка не должен ронять ввод остатков: кладовщик продолжит проход,
        // просто без страховки. Молча — сообщать здесь нечего и некому.
        .catchError((_) {});
  }

  /// Отбросить проход целиком — по явному требованию кладовщика.
  ///
  /// Слепок стирать отдельно не нужно: перехват [emit] сам чистит хранилище, когда проход стал
  /// пустым. Ждём запись, чтобы вызывающий мог уйти с экрана, зная, что на диске уже пусто.
  ///
  /// ⚠ Это единственный способ потерять проход намеренно. Выход с экрана его НЕ трогает:
  /// проход durable с P2-03 и восстановится при следующем открытии.
  Future<void> discardPass() async {
    emit(const StockEntryState());
    await _writes;
  }

  /// Дождаться записи слепка. Нужно только тестам: запись идёт вне вызова [emit], и без
  /// этого проверка «состояние сохранилось» гонялась бы с самой записью.
  @visibleForTesting
  Future<void> get draftWrites => _writes;

  final StockEntryRepository _repo;

  /// Выбрать ячейку для работы. Если ячейка уже пройдена — открываем её на редактирование:
  /// забираем строки в буфер и убираем из списка пройденных (вернётся при «Завершить ячейку»).
  void selectCell(Cell cell) {
    final idx = state.committedCells.indexWhere((c) => c.cell.id == cell.id);
    if (idx >= 0) {
      final existing = state.committedCells[idx];
      final committed = List<CommittedCell>.from(state.committedCells)
        ..removeAt(idx);
      emit(
        state.copyWith(
          cell: cell,
          lines: existing.lines,
          undoStack: const [],
          committedCells: committed,
          failure: null,
        ),
      );
    } else {
      emit(
        state.copyWith(
          cell: cell,
          lines: const [],
          undoStack: const [],
          failure: null,
        ),
      );
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
    emit(
      state.copyWith(
        cell: newCell,
        lines: lines,
        committedCells: committed,
        undoStack: const [],
        failure: null,
      ),
    );
  }

  /// Слить строки `add` в `base` по грани (товар, дата): совпало → сумма qty; иначе — новая строка.
  List<EntryLineDraft> _mergeLines(
    List<EntryLineDraft> base,
    List<EntryLineDraft> add,
  ) {
    final out = List<EntryLineDraft>.from(base);
    for (final l in add) {
      final i = out.indexWhere(
        (x) => x.good.id == l.good.id && x.productionDate == l.productionDate,
      );
      if (i >= 0) {
        out[i] = out[i].copyWith(qty: out[i].qty + l.qty);
      } else {
        out.add(l);
      }
    }
    return out;
  }

  /// Резолв товара по ШК — через общий кэш-first репозиторий справочников.
  ///
  /// **Почему не своим запросом.** Поток ввода держал собственную реализацию поверх `Dio`, мимо
  /// кэша устройства (P2-02): без связи скан не опознавал даже товар, привязка которого лежит
  /// в локальной базе. Две реализации одного действия расходятся — это уже разбиралось в P2-06.
  ///
  /// **Исход возвращается целиком, а не сводится к `Good?`.** Прежде и «ШК не привязан», и
  /// «проверить не удалось» давали `null`, и вызывающий открывал привязку в обоих случаях —
  /// то есть офлайн кладовщик привязывал код, про который приложение просто не смогло узнать.
  /// Это ровно дефект ADHOC-06, в «Остатках» закрытый, а здесь оставшийся. Цена его тут выше:
  /// от привязки зависит, на какой товар ляжет остаток.
  ///
  /// Ошибку в state не кладём: проход остался валидным, и решает вызывающий.
  Future<Either<Failure, Good?>> resolveBarcode(String code) =>
      _catalog.resolveGoodByBarcode(code);

  /// Добавить/накопить строку. Грань (good, date): та же дата → +qty; другая дата → новая строка.
  ///
  /// [newBarcode] — товар опознан ранее НЕизвестным ШК, кладовщик выбрал его вручную. Привязка
  /// уходит **обычной операцией очереди** (ADHOC-14), тем же путём, что из карточки товара
  /// в «Остатках»: ляжет в кэш с пометкой «ожидает», уедет сама при появлении связи, а конфликт
  /// «ШК уже за другим товаром» будет виден на экране несинхронизированного.
  ///
  /// Прежде привязки копились в состоянии прохода и уезжали одним куском с первым checkpoint'ом
  /// на финале. Это связывало вещи, которые связывать не нужно: строка остатка ссылается на товар
  /// напрямую, привязка ей не требуется, — а на сервере они лежали в одной транзакции, и один
  /// конфликтный ШК откатывал вместе с собой просчёт целой ячейки.
  ///
  /// Перед изменением — снимок в Undo; в нём запоминается добавленный код, чтобы отмена шага
  /// могла снять привязку, пока та не ушла.
  Future<void> addLine({
    required Good good,
    required String date,
    required double qty,
    String? newBarcode,
    String? symbology,
  }) async {
    final snapLines = List<EntryLineDraft>.from(state.lines);
    final lines = List<EntryLineDraft>.from(state.lines);
    final idx = lines.indexWhere(
      (l) => l.good.id == good.id && l.productionDate == date,
    );
    if (idx >= 0) {
      lines[idx] = lines[idx].copyWith(qty: lines[idx].qty + qty);
    } else {
      lines.add(EntryLineDraft(good: good, productionDate: date, qty: qty));
    }
    // Строка кладётся ДО постановки привязки и синхронно: она видна кладовщику сразу, а ждать
    // записи в очередь ей незачем — от привязки строка не зависит. Порядок наоборот сделал бы
    // добавление строки асинхронным, и вызывающий, не поставивший await, увидел бы буфер
    // без только что добавленной строки.
    _commit(snapLines, lines, addedBarcode: newBarcode);

    if (newBarcode != null) {
      // Исход не разбираем: очередь примет операцию в любом случае, а отказ по существу
      // покажет экран разбора. Строка остатка от этого не зависит — товар выбран руками.
      await _catalog.bindBarcode(goodId: good.id, barcode: newBarcode);
    }
  }

  /// Удалить строку из буфера (по грани good+partiya). Кладёт снимок в Undo. Привязку ШК НЕ трогаем:
  /// идентификация товара остаётся валидной, даже если строку количества убрали.
  void removeLine(EntryLineDraft line) {
    final lines = state.lines
        .where(
          (l) =>
              !(l.good.id == line.good.id &&
                  l.productionDate == line.productionDate),
        )
        .toList();
    // не нашли — ничего не делаем
    if (lines.length == state.lines.length) {
      return;
    }
    _commit(List<EntryLineDraft>.from(state.lines), lines);
  }

  /// Отредактировать строку: новые дата и количество (замена, не приращение). Если новая грань
  /// (тот же товар, новая дата) совпала с другой строкой — сливаем количества в неё. Кладёт снимок в Undo.
  void editLine(
    EntryLineDraft target, {
    required String date,
    required double qty,
  }) {
    final lines = List<EntryLineDraft>.from(state.lines);
    final idx = lines.indexWhere(
      (l) =>
          l.good.id == target.good.id &&
          l.productionDate == target.productionDate,
    );
    if (idx < 0) return;

    final edited = lines[idx];
    final dupIdx = lines.indexWhere(
      (l) => l.good.id == edited.good.id && l.productionDate == date,
    );
    if (dupIdx >= 0 && dupIdx != idx) {
      // Новая дата совпала с уже существующей партией того же товара → слить количества.
      lines[dupIdx] = lines[dupIdx].copyWith(qty: lines[dupIdx].qty + qty);
      lines.removeAt(idx);
    } else {
      lines[idx] = edited.copyWith(productionDate: date, qty: qty);
    }
    _commit(List<EntryLineDraft>.from(state.lines), lines);
  }

  /// Применить новый буфер, положив предыдущий снимок (строки + копилка ШК) в стек Undo (глубина
  /// [kUndoDepth]).
  void _commit(
    List<EntryLineDraft> snapLines,
    List<EntryLineDraft> newLines, {
    String? addedBarcode,
  }) {
    final undo = [
      ...state.undoStack,
      BufferSnapshot(lines: snapLines, addedBarcode: addedBarcode),
    ];
    final capped = undo.length > kUndoDepth
        ? undo.sublist(undo.length - kUndoDepth)
        : undo;
    emit(state.copyWith(lines: newLines, undoStack: capped, failure: null));
  }

  /// Снять ошибочную привязку ШК, сделанную в проходе (P-FS-12, переработано в ADHOC-14).
  ///
  /// Сначала пробуем отменить операцию, пока она не ушла. Не успели — шлём отвязку: код уже
  /// на сервере или в пути, и убрать его можно только там. Обе ветки идут через очередь, так что
  /// обе переживут отсутствие связи.
  Future<void> removeBarcode(String code, {required String goodId}) async {
    if (await _catalog.cancelPendingBind(code)) return;
    await _catalog.unbindBarcode(goodId: goodId, barcode: code);
  }

  /// Отменить последний шаг буфера: вернуть строки и снять привязку, сделанную этим шагом.
  ///
  /// **Привязка снимается, только если ещё не ушла на сервер** (решение пользователя, ADHOC-14).
  /// Ушедшую отзывать нечем: она уже в справочнике или в полёте, и «отмена» стала бы обещанием,
  /// которого приложение не выполняет. Убрать такую можно кнопкой «неверный товар» — та шлёт
  /// отвязку.
  Future<void> undo() async {
    if (state.undoStack.isEmpty) return;
    final prev = state.undoStack.last;
    emit(
      state.copyWith(
        lines: prev.lines,
        undoStack: state.undoStack.sublist(0, state.undoStack.length - 1),
      ),
    );
    final code = prev.addedBarcode;
    if (code != null) await _catalog.cancelPendingBind(code);
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
    emit(
      state.copyWith(
        cell: null,
        lines: const [],
        undoStack: const [],
        committedCells: committed,
        failure: null,
      ),
    );
  }

  /// Удалить пройденную ячейку из списка (ошибочный просчёт).
  void removeCommittedCell(String cellId) {
    final committed = state.committedCells
        .where((c) => c.cell.id != cellId)
        .toList();
    if (committed.length == state.committedCells.length) return;
    emit(state.copyWith(committedCells: committed));
  }

  /// Завершить ввод остатков: старт сессии → checkpoint каждой пройденной ячейки → финал. Всё
  /// отправляется на сервер здесь. При ошибке — прерываемся; sessionId сохраняем, чтобы ретрай
  /// переиспользовал ту же сессию (checkpoint идемпотентен по грани, лишних сессий не плодим).
  Future<void> finishSession() async {
    if (state.cell != null || state.committedCells.isEmpty || state.busy) {
      return;
    }
    emit(state.copyWith(busy: true, failure: null));

    var sid = state.sessionId;
    if (sid == null) {
      final startRes = await _repo.startSession(
        state.committedCells.first.cell.warehouseId,
      );
      final ok = startRes.fold(
        (f) {
          emit(state.copyWith(busy: false, failure: f));
          return false;
        },
        (id) {
          sid = id;
          return true;
        },
      );
      if (!ok) return;
      emit(
        state.copyWith(sessionId: sid),
      ); // сохранить, чтобы ретрай не плодил сессии
    }

    // Привязки ШК с checkpoint'ом больше не едут (ADHOC-14): они уходят своими операциями
    // очереди. Прежде вся копилка прохода везлась с ПЕРВЫМ checkpoint, и на сервере привязки
    // лежали с строками ячейки в одной транзакции — один конфликтный ШК откатывал вместе с собой
    // просчёт целой ячейки, хотя строка остатка от привязки не зависит.
    for (var i = 0; i < state.committedCells.length; i++) {
      final cc = state.committedCells[i];
      final res = await _repo.checkpoint(
        sessionId: sid!,
        cellId: cc.cell.id,
        lines: _linesPayload(cc.lines),
        newBarcodes: const [],
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
      (written) => emit(
        state.copyWith(
          busy: false,
          finished: true,
          written: written,
          failure: null,
        ),
      ),
    );
  }

  /// Строки ячейки → payload API. Дата в UI хранится с точками (дд.мм.гггг); API ждёт DD-MM-YYYY.
  List<Map<String, dynamic>> _linesPayload(List<EntryLineDraft> lines) => lines
      .map(
        (l) => <String, dynamic>{
          'good_id': l.good.id,
          'production_date': l.productionDate.replaceAll('.', '-'),
          'qty': l.qty,
        },
      )
      .toList();

  /// Сбросить ошибку (после показа пользователю).
  void clearFailure() => emit(state.copyWith(failure: null));
}
