import 'package:either_dart/either.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:injectable/injectable.dart';

import '../../../../core/error/failure.dart';
import '../../../../core/load_unit/load_unit_id_generator.dart';
import '../../../../core/printer/printer_device.dart';
import '../../../../core/printer/printer_service.dart';
import '../../../cz/domain/cz_intake.dart';
import '../../../cz/domain/cz_intake_hold.dart';
import '../../../stock/data/catalog_models.dart';
import '../../data/entry_draft_store.dart';
import '../../../stock/data/catalog_repository.dart';
import '../../domain/entry_buffer.dart';
import '../../domain/entry_models.dart';
import '../../domain/stock_entry_repository.dart';

part 'stock_entry_cubit.freezed.dart';

/// Максимум операций отмены (буфер текущей ячейки).
const int kUndoDepth = 10;

/// Маркер отказа «очередь не отправлена» - экран переводит его в текст: проход с марками
/// завершается только после того, как привязки ШК из марок дошли до сервера.
const String kQueuePending = 'queue_pending';

/// Снимок буфера ячейки для Undo: строки, короба и упаковки ЧЗ + ШК, привязанный на шаге.
/// ШК включён в снимок, чтобы отмена откатывала и ошибочную привязку, а не только количество.
@freezed
abstract class BufferSnapshot with _$BufferSnapshot {
  const factory BufferSnapshot({
    required List<EntryLineDraft> lines,
    @Default(<EntryBox>[]) List<EntryBox> boxes,
    @Default(<CzGroupDraft>[]) List<CzGroupDraft> czGroups,

    /// ШК, привязанный на этом шаге, если он был. Отмена шага пытается снять эту привязку,
    /// пока та не ушла на сервер (ADHOC-14). Раньше здесь лежала вся копилка прохода -
    /// с переходом привязок в очередь хранить её в снимке стало нечего.
    String? addedBarcode,
  }) = _BufferSnapshot;
}

/// Состояние экрана-потока ввода остатков. Вариант A: всё копится в памяти ТСД; на сервер уходит
/// одним махом при «Завершить ввод» (старт сессии → checkpoint каждой ячейки → финал). Пройденные
/// ячейки редактируемы до финала.
@freezed
abstract class StockEntryState with _$StockEntryState {
  const factory StockEntryState({
    Cell? cell, // текущая редактируемая ячейка (null - экран выбора ячейки)
    @Default(<EntryLineDraft>[])
    List<EntryLineDraft> lines, // буфер текущей ячейки
    /// Короба текущей ячейки (ADHOC-46): свои с QR и короба ЧЗ.
    @Default(<EntryBox>[]) List<EntryBox> boxes,

    /// Групповые упаковки ЧЗ текущей ячейки (ADHOC-46).
    @Default(<CzGroupDraft>[]) List<CzGroupDraft> czGroups,
    @Default(<BufferSnapshot>[]) List<BufferSnapshot> undoStack,
    @Default(<CommittedCell>[])
    List<CommittedCell> committedCells, // пройденные ячейки (локально)
    String? sessionId, // серверная сессия - создаётся только на финале
    @Default(false) bool busy, // сетевая операция финала
    @Default(false) bool finished, // финал выполнен
    @Default(0) int written, // записано строк в stock (после финала)
    Failure? failure,
  }) = _StockEntryState;

  const StockEntryState._();

  /// Можно завершить ввод: есть пройденные ячейки, текущая не в работе, не идёт сетевой финал.
  bool get canFinishSession =>
      committedCells.isNotEmpty && cell == null && !busy;

  /// Короб текущей ячейки по идентификатору; `null` - такого нет.
  EntryBox? boxById(String id) => boxes.where((b) => b.id == id).firstOrNull;

  /// Строки короба текущей ячейки.
  List<EntryLineDraft> linesOf(String boxId) =>
      lines.where((l) => l.boxId == boxId).toList();

  /// Строки россыпью текущей ячейки.
  List<EntryLineDraft> get looseLines =>
      lines.where((l) => l.boxId == null).toList();

  /// Все строки прохода: пройденные ячейки и текущая.
  Iterable<EntryLineDraft> get passLines => [
    for (final c in committedCells) ...c.lines,
    ...lines,
  ];

  /// Все короба прохода.
  Iterable<EntryBox> get passBoxes => [
    for (final c in committedCells) ...c.boxes,
    ...boxes,
  ];

  /// Все упаковки ЧЗ прохода.
  Iterable<CzGroupDraft> get passGroups => [
    for (final c in committedCells) ...c.czGroups,
    ...czGroups,
  ];
}

/// Cubit ввода остатков (вариант A): буфер ячейки, Undo, список пройденных ячеек (локально),
/// финал одним пакетом. Фабрика (свой на экран).
@injectable
class StockEntryCubit extends Cubit<StockEntryState> {
  StockEntryCubit(
    this._repo,
    this._catalog,
    this._drafts,
    this._ids,
    this._printer,
  ) : super(const StockEntryState());

  final CatalogRepository _catalog;
  final EntryDraftStore _drafts;

  /// Марки ЧЗ, отсканированные, но ещё не легшие в проход (ADHOC-70): закрытие ячейки, уход и
  /// финал ждут их.
  final czHold = CzIntakeHold();
  final LoadUnitIdGenerator _ids;
  final PrinterService _printer;

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
  /// Что НЕ входит: [StockEntryState.undoStack] - Undo служит текущему действию, переживать
  /// перезапуск ему незачем; [StockEntryState.busy] и [StockEntryState.failure] - они описывают
  /// сетевой вызов, которого после перезапуска уже нет.
  ///
  /// [StockEntryState.sessionId] входит: если процесс умер посреди финала, сессия на сервере
  /// уже создана, и повторный финал без её идентификатора завёл бы вторую.
  Map<String, dynamic> _draftJson(StockEntryState s) => {
    'cell': s.cell?.toJson(),
    'lines': s.lines.map((l) => l.toJson()).toList(),
    'boxes': s.boxes.map((b) => b.toJson()).toList(),
    'cz_groups': s.czGroups.map((g) => g.toJson()).toList(),
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
      boxes: (draft['boxes'] as List<dynamic>? ?? const [])
          .map((e) => EntryBox.fromJson(e as Map<String, dynamic>))
          .toList(),
      czGroups: (draft['cz_groups'] as List<dynamic>? ?? const [])
          .map((e) => CzGroupDraft.fromJson(e as Map<String, dynamic>))
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
    // Финал прошёл - проход больше не нужен; пустой проход тоже не храним.
    final done = state.finished || !_hasDraft(state);
    final snapshot = done ? null : _draftJson(state);
    _writes = _writes
        .then(
          (_) => snapshot == null ? _drafts.clear() : _drafts.save(snapshot),
        )
        // Сбой записи слепка не должен ронять ввод остатков: кладовщик продолжит проход,
        // просто без страховки. Молча - сообщать здесь нечего и некому.
        .catchError((_) {});
  }

  /// Отбросить проход целиком - по явному требованию кладовщика.
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

  /// Выбрать ячейку для работы. Если ячейка уже пройдена - открываем её на редактирование:
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
          boxes: existing.boxes,
          czGroups: existing.czGroups,
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
          boxes: const [],
          czGroups: const [],
          undoStack: const [],
          failure: null,
        ),
      );
    }
  }

  /// Сменить целевую ячейку текущего буфера, СОХРАНИВ набранные строки и короба (ошиблись
  /// ячейкой, товары верны - перецеливаем, не пересканируя). Короба едут вместе с ячейкой: у
  /// короба прохода своей ячейки нет. Если новая ячейка уже пройдена - сливаем её содержимое в
  /// буфер по грани (товар, дата, короб) и убираем из пройденных: checkpoint ячейки заменяет её
  /// содержимое в сессии, и два checkpoint'а одной ячейки оставили бы только последний. Undo
  /// сбрасываем - это структурная смена, а не правка буфера.
  void changeCell(Cell newCell) {
    final current = state.cell;
    if (current == null || current.id == newCell.id) return;
    var lines = state.lines;
    var boxes = state.boxes;
    var groups = state.czGroups;
    var committed = state.committedCells;
    final idx = committed.indexWhere((c) => c.cell.id == newCell.id);
    if (idx >= 0) {
      final other = committed[idx];
      lines = mergeEntryLines(state.lines, other.lines);
      boxes = [...boxes, ...other.boxes];
      groups = [...groups, ...other.czGroups];
      committed = List<CommittedCell>.from(committed)..removeAt(idx);
    }
    emit(
      state.copyWith(
        cell: newCell,
        lines: lines,
        boxes: boxes,
        czGroups: groups,
        committedCells: committed,
        undoStack: const [],
        failure: null,
      ),
    );
  }

  /// Резолв товара по ШК - через общий кэш-first репозиторий справочников.
  ///
  /// **Почему не своим запросом.** Поток ввода держал собственную реализацию поверх `Dio`, мимо
  /// кэша устройства (P2-02): без связи скан не опознавал даже товар, привязка которого лежит
  /// в локальной базе. Две реализации одного действия расходятся - это уже разбиралось в P2-06.
  ///
  /// **Исход возвращается целиком, а не сводится к `Good?`.** Прежде и «ШК не привязан», и
  /// «проверить не удалось» давали `null`, и вызывающий открывал привязку в обоих случаях -
  /// то есть офлайн кладовщик привязывал код, про который приложение просто не смогло узнать.
  /// Это ровно дефект ADHOC-06, в «Остатках» закрытый, а здесь оставшийся. Цена его тут выше:
  /// от привязки зависит, на какой товар ляжет остаток.
  ///
  /// Ошибку в state не кладём: проход остался валидным, и решает вызывающий.
  Future<Either<Failure, Good?>> resolveBarcode(String code) =>
      _catalog.resolveGoodByBarcode(code);

  /// Добавить/накопить строку. Грань (good, date): та же дата → +qty; другая дата → новая строка.
  ///
  /// [newBarcode] - товар опознан ранее НЕизвестным ШК, кладовщик выбрал его вручную. Привязка
  /// уходит **обычной операцией очереди** (ADHOC-14), тем же путём, что из карточки товара
  /// в «Остатках»: ляжет в кэш с пометкой «ожидает», уедет сама при появлении связи, а конфликт
  /// «ШК уже за другим товаром» будет виден на экране несинхронизированного.
  ///
  /// Прежде привязки копились в состоянии прохода и уезжали одним куском с первым checkpoint'ом
  /// на финале. Это связывало вещи, которые связывать не нужно: строка остатка ссылается на товар
  /// напрямую, привязка ей не требуется, - а на сервере они лежали в одной транзакции, и один
  /// конфликтный ШК откатывал вместе с собой просчёт целой ячейки.
  ///
  /// Перед изменением - снимок в Undo; в нём запоминается добавленный код, чтобы отмена шага
  /// могла снять привязку, пока та не ушла.
  ///
  /// [boxId] - свой короб прохода (ADHOC-46); `null` - россыпь. В короб ЧЗ не кладут: его
  /// состав - из ЧЗ (экран сюда не пускает - страховка).
  Future<void> addLine({
    required Good good,
    required String date,
    required double qty,
    String? newBarcode,
    String? symbology,
    String? boxId,
  }) async {
    if (boxId != null && (state.boxById(boxId)?.isCz ?? true)) return;
    final snapLines = List<EntryLineDraft>.from(state.lines);
    final lines = addEntryQty(
      state.lines,
      good: good,
      date: date,
      qty: qty,
      boxId: boxId,
    );
    // Строка кладётся ДО постановки привязки и синхронно: она видна кладовщику сразу, а ждать
    // записи в очередь ей незачем - от привязки строка не зависит. Порядок наоборот сделал бы
    // добавление строки асинхронным, и вызывающий, не поставивший await, увидел бы буфер
    // без только что добавленной строки.
    _commit(snapLines, lines, addedBarcode: newBarcode);

    if (newBarcode != null) {
      // Исход не разбираем: очередь примет операцию в любом случае, а отказ по существу
      // покажет экран разбора. Строка остатка от этого не зависит - товар выбран руками.
      await _catalog.bindBarcode(goodId: good.id, barcode: newBarcode);
    }
  }

  /// Удалить строку из буфера (по грани товар, партия, короб) - вместе с её марками. Кладёт
  /// снимок в Undo. Привязку ШК НЕ трогаем: идентификация товара остаётся валидной, даже если
  /// строку количества убрали.
  void removeLine(EntryLineDraft line) {
    final lines = state.lines
        .where(
          (l) => !l.sameGrain(line.good.id, line.productionDate, line.boxId),
        )
        .toList();
    // не нашли - ничего не делаем
    if (lines.length == state.lines.length) {
      return;
    }
    _commit(List<EntryLineDraft>.from(state.lines), lines);
  }

  /// Отредактировать строку: новые дата и количество (замена, не приращение). Если новая грань
  /// (тот же товар, новая дата) совпала с другой строкой - сливаем количества в неё. Кладёт снимок в Undo.
  ///
  /// Строку с марками ЧЗ не правят: количество - число марок, партия - из ЧЗ.
  void editLine(
    EntryLineDraft target, {
    required String date,
    required double qty,
  }) {
    if (target.marks.isNotEmpty) return;
    final lines = List<EntryLineDraft>.from(state.lines);
    final idx = lines.indexWhere(
      (l) => l.sameGrain(target.good.id, target.productionDate, target.boxId),
    );
    if (idx < 0) return;

    final edited = lines[idx];
    final dupIdx = lines.indexWhere(
      (l) => l.sameGrain(edited.good.id, date, edited.boxId),
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

  /// Применить новый буфер, положив предыдущий снимок (строки, короба, упаковки + ШК шага) в
  /// стек Undo (глубина [kUndoDepth]).
  void _commit(
    List<EntryLineDraft> snapLines,
    List<EntryLineDraft> newLines, {
    String? addedBarcode,
    List<EntryBox>? boxes,
    List<CzGroupDraft>? czGroups,
  }) {
    final undo = [
      ...state.undoStack,
      BufferSnapshot(
        lines: snapLines,
        boxes: state.boxes,
        czGroups: state.czGroups,
        addedBarcode: addedBarcode,
      ),
    ];
    final capped = undo.length > kUndoDepth
        ? undo.sublist(undo.length - kUndoDepth)
        : undo;
    emit(
      state.copyWith(
        lines: newLines,
        boxes: boxes ?? state.boxes,
        czGroups: czGroups ?? state.czGroups,
        undoStack: capped,
        failure: null,
      ),
    );
  }

  //* --- короба и марки «Честного знака» (ADHOC-46) --- *//

  /// Новый свой короб в текущей ячейке. Возвращает идентификатор - по нему открывают страницу
  /// короба; ярлык кладовщик печатает со страницы короба, как на приёмке. Короб создаётся на
  /// терминале, без сети: ГЕ на сервере появится на финале ввода.
  String newBox() {
    final box = EntryBox(id: _ids.newId());
    emit(state.copyWith(boxes: [...state.boxes, box], failure: null));
    return box.id;
  }

  /// Есть ли в текущей ячейке короб с таким идентификатором (скан ярлыка).
  bool hasBox(String loadUnitId) =>
      state.boxById(loadUnitId.toLowerCase()) != null;

  /// Короб в другой пройденной ячейке этого прохода (скан ярлыка не своей ячейки).
  bool boxInOtherCell(String loadUnitId) {
    final id = loadUnitId.toLowerCase();
    return state.committedCells.any((c) => c.boxes.any((b) => b.id == id));
  }

  /// Удалить короб с его строками и марками; у короба ЧЗ - и его упаковки. Кладёт снимок в
  /// Undo: ошибочное удаление короба ЧЗ иначе пришлось бы сканировать заново.
  void removeBox(String boxId) {
    final cz = state.boxById(boxId)?.czCode;
    _commit(
      List<EntryLineDraft>.from(state.lines),
      state.lines.where((l) => l.boxId != boxId).toList(),
      boxes: state.boxes.where((b) => b.id != boxId).toList(),
      czGroups: cz == null
          ? state.czGroups
          : groupsOutsideBox(state.czGroups, cz),
    );
  }

  /// Короб ЧЗ этого прохода по коду SSCC: в текущей ячейке - его id; в другой ячейке или нет
  /// вовсе - `null`.
  String? czBoxIdByCode(String code) =>
      state.boxes.where((b) => b.czCode == code).firstOrNull?.id;

  /// Короб ЧЗ целиком: новая ГЕ в текущей ячейке, строки - состав по ЧЗ, по товару и партии.
  /// Возвращает исход и, если короб лёг, его идентификатор.
  ({CzIntakeAdd result, String? boxId}) addCzBox({
    required String code,
    required List<CzIntakeLine> lines,
    List<CzGroupDraft> groups = const [],
  }) {
    if (state.passBoxes.any((b) => b.czCode == code) ||
        entryMarksTaken(state.passLines, lines)) {
      return (result: CzIntakeAdd.duplicate, boxId: null);
    }
    final box = EntryBox(id: _ids.newId(), czCode: code);
    _commit(
      List<EntryLineDraft>.from(state.lines),
      addEntryMarks(state.lines, lines, boxId: box.id),
      boxes: [...state.boxes, box],
      czGroups: [...state.czGroups, ...groups],
    );
    return (result: CzIntakeAdd.added, boxId: box.id);
  }

  /// Марки - одна марка или групповая упаковка набором своих марок: в свой короб [boxId] или
  /// россыпью текущей ячейки. Товар и партия - из ЧЗ, без диалога: каждая марка - единица.
  CzIntakeAdd addCzMarks({
    required List<CzIntakeLine> lines,
    List<CzGroupDraft> groups = const [],
    String? boxId,
  }) {
    if (boxId != null && (state.boxById(boxId)?.isCz ?? true)) {
      return CzIntakeAdd.czBoxClosed;
    }
    if (entryMarksTaken(state.passLines, lines) ||
        groups.any((g) => state.passGroups.any((e) => e.code == g.code))) {
      return CzIntakeAdd.duplicate;
    }
    _commit(
      List<EntryLineDraft>.from(state.lines),
      addEntryMarks(state.lines, lines, boxId: boxId),
      czGroups: [...state.czGroups, ...groups],
    );
    return CzIntakeAdd.added;
  }

  /// Напечатать ярлык своего короба. Возвращает текст ошибки или `null`. Неудача печати проход
  /// не останавливает: короб уже заведён, ярлык можно допечатать со страницы короба.
  Future<String?> printBoxLabel(String boxId) async {
    try {
      await _printer.printLoadUnitLabel(boxId);
      return null;
    } on PrinterFailure catch (e) {
      return e.userMessage;
    } catch (e) {
      return e.toString();
    }
  }

  /// Снять ошибочную привязку ШК, сделанную в проходе (P-FS-12, переработано в ADHOC-14).
  ///
  /// Сначала пробуем отменить операцию, пока она не ушла. Не успели - шлём отвязку: код уже
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
  /// которого приложение не выполняет. Убрать такую можно кнопкой «неверный товар» - та шлёт
  /// отвязку.
  Future<void> undo() async {
    if (state.undoStack.isEmpty) return;
    final prev = state.undoStack.last;
    emit(
      state.copyWith(
        lines: prev.lines,
        boxes: prev.boxes,
        czGroups: prev.czGroups,
        undoStack: state.undoStack.sublist(0, state.undoStack.length - 1),
      ),
    );
    final code = prev.addedBarcode;
    if (code != null) await _catalog.cancelPendingBind(code);
  }

  /// Завершить ячейку: положить её в список пройденных (локально, без сети) вместе с коробами
  /// и упаковками. Пустую (без строк) не добавляем; пустые короба не берём - на сервер они и
  /// не уехали бы. Затем - экран выбора ячейки.
  void finishCell() {
    final cell = state.cell;
    if (cell == null) return;
    final committed = List<CommittedCell>.from(state.committedCells);
    if (state.lines.isNotEmpty) {
      final used = state.lines.map((l) => l.boxId).nonNulls.toSet();
      committed.add(
        CommittedCell(
          cell: cell,
          lines: state.lines,
          boxes: state.boxes.where((b) => used.contains(b.id)).toList(),
          czGroups: state.czGroups,
        ),
      );
    }
    emit(
      state.copyWith(
        cell: null,
        lines: const [],
        boxes: const [],
        czGroups: const [],
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
  /// отправляется на сервер здесь. При ошибке - прерываемся; sessionId сохраняем, чтобы ретрай
  /// переиспользовал ту же сессию (checkpoint заменяет ячейку в сессии, лишних сессий не плодим).
  ///
  /// Проход с марками ЧЗ сначала отправляет очередь: финал сверяет GTIN марки с ШК товара, а
  /// привязка ШК из марки едет операцией очереди (ADHOC-46). Очередь не ушла - финал ждёт.
  Future<void> finishSession() async {
    if (state.cell != null || state.committedCells.isEmpty || state.busy) {
      return;
    }
    emit(state.copyWith(busy: true, failure: null));
    if (state.passLines.any((l) => l.marks.isNotEmpty) &&
        !await _repo.drainQueue()) {
      emit(
        state.copyWith(
          busy: false,
          failure: const Failure.unknown(kQueuePending),
        ),
      );
      return;
    }

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
    // лежали с строками ячейки в одной транзакции - один конфликтный ШК откатывал вместе с собой
    // просчёт целой ячейки, хотя строка остатка от привязки не зависит.
    for (var i = 0; i < state.committedCells.length; i++) {
      final cc = state.committedCells[i];
      final res = await _repo.checkpoint(
        sessionId: sid!,
        body: entryCellBody(cc),
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

  /// Сбросить ошибку (после показа пользователю).
  void clearFailure() => emit(state.copyWith(failure: null));
}
