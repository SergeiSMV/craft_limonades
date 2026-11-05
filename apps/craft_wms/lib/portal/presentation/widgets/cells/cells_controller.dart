import 'package:flutter/foundation.dart';

import '../../../../core/error/failure.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../data/cells_repository.dart';
import '../../../domain/cells/cell_setup.dart';
import '../../../domain/cells/cells_view.dart';

/// Состояние страницы «Ячейки» (ADHOC-57): ячейки склада, фильтры, выбор и несохранённые
/// галочки карточки ячейки.
///
/// Зачем отдельный контроллер, а не `setState` вкладки: на узком окне карточка ячейки
/// открывается окном поверх страницы, и окно должно видеть те же галочки, что и страница.
/// Как: выбор — либо одна ячейка «в фокусе» (нажали на строку), либо отмеченные галочками
/// строки; смена выбора сбрасывает несохранённые галочки. Галочка с чертой (у части выборки)
/// по нажатию ставится всем.
class CellsController extends ChangeNotifier {
  CellsController(this._repo);

  final CellsRepository _repo;

  /// Строк списка за раз; дальше — «Показать ещё».
  static const pageSize = 50;

  CellsView? view;
  String? loadError;
  CellsFilter filter = const CellsFilter();
  int shown = pageSize;

  String? focusId;
  final Set<String> picked = {};
  final Map<CellFlag, bool> draft = {};
  bool saving = false;
  String? saveError;

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Ячейки и стеллажи склада с сервера. Выбор переживает перечитывание: ячейки, которых
  /// больше нет, из него выпадают.
  Future<void> load() async {
    final res = await _repo.loadSetup();
    res.fold((f) => loadError = failureText(f), _apply);
    _notify();
  }

  /// Принять прочитанные ячейки: выбор без исчезнувших ячеек, ошибка чтения снята.
  void _apply(CellsSetup setup) {
    final v = CellsView(setup);
    final ids = {for (final c in v.cells) c.id};
    picked.retainWhere(ids.contains);
    if (focusId != null && !ids.contains(focusId)) focusId = null;
    view = v;
    loadError = null;
  }

  /// Есть несохранённые галочки карточки или идёт их сохранение.
  bool get hasUnsaved => draft.isNotEmpty || saving;

  /// Ячейки изменились на сервере (ADHOC-60): перечитать, только если на странице нет
  /// несохранённых галочек — иначе молча пропустить, чтобы не сбить правку (сохранение само
  /// перечитает склад). Ошибка тихого чтения не показывается: список остаётся прежним.
  /// Фильтр, число показанных строк и выбор сохраняются — их держит контроллер, [load] их
  /// не сбрасывает.
  Future<void> reloadIfClean() async {
    if (hasUnsaved) return;
    final res = await _repo.loadSetup();
    if (res.isLeft || _disposed) return;
    _apply(res.right);
    _notify();
  }

  /// Ячейки под фильтр — весь список, не только показанные строки.
  List<CellSetup> get rows => view?.filtered(filter) ?? const [];

  /// Показанные строки: первые [shown] под фильтр.
  List<CellSetup> get visible => rows.take(shown).toList();

  /// Кого правит карточка: отмеченные строки, а без них — ячейка в фокусе.
  List<CellSetup> get targets {
    final v = view;
    if (v == null) return const [];
    if (picked.isNotEmpty) {
      return [
        for (final c in v.cells)
          if (picked.contains(c.id)) c,
      ];
    }
    return [
      for (final c in v.cells)
        if (c.id == focusId) c,
    ];
  }

  /// Новые фильтры; список снова с первой страницы.
  void setFilter(CellsFilter f) {
    filter = f;
    shown = pageSize;
    _notify();
  }

  void showMore() {
    shown += pageSize;
    _notify();
  }

  /// Нажали на строку: она в фокусе, отметки сняты.
  void focus(String id) {
    picked.clear();
    focusId = id;
    _resetDraft();
  }

  /// Галочка строки.
  void togglePick(String id) {
    picked.contains(id) ? picked.remove(id) : picked.add(id);
    _resetDraft();
  }

  /// Галочка шапки: все ячейки под фильтр отмечены — снять с них, иначе отметить все под
  /// фильтр, включая ещё не показанные строки. Отметки вне фильтра не трогаются.
  void togglePickFiltered() {
    final ids = rows.map((c) => c.id).toList();
    final all = ids.every(picked.contains);
    all ? picked.removeAll(ids) : picked.addAll(ids);
    _resetDraft();
  }

  void unpickAll() {
    picked.clear();
    _resetDraft();
  }

  /// Значение галочки карточки: несохранённое, а без него — сводное по выборке.
  bool? value(CellFlag flag) {
    if (draft.containsKey(flag)) return draft[flag];
    // Сводная может быть `null` (черта) — её не подменять на «снято».
    final v = view;
    return v == null ? false : v.aggregate(targets, flag);
  }

  /// Нажали на галочку карточки: снятая и с чертой ставятся, стоящая снимается. Вернулась к
  /// сохранённому — несохранённой правки нет.
  void toggle(CellFlag flag) {
    final next = value(flag) != true;
    if (next == view?.aggregate(targets, flag)) {
      draft.remove(flag);
    } else {
      draft[flag] = next;
    }
    saveError = null;
    _notify();
  }

  void resetDraft() => _resetDraft();

  void _resetDraft() {
    draft.clear();
    saveError = null;
    _notify();
  }

  /// Сохранить галочки выборки и перечитать склад. Текст об успехе — для уведомления;
  /// `null` — не сохранено (ошибка — в [saveError]).
  Future<String?> save() async {
    final list = targets;
    if (draft.isEmpty || list.isEmpty || saving) return null;
    saving = true;
    saveError = null;
    _notify();
    final res = await _repo.saveSettings([
      for (final c in list) c.id,
    ], Map.of(draft));
    saving = false;
    if (res.isLeft) {
      saveError = failureText(res.left);
      _notify();
      return null;
    }
    final n = res.right;
    draft.clear();
    await load();
    return t.portal.cells.side.saved(cells: n);
  }
}

/// Текст ошибки для оператора: текст сервера как есть (причины 409 и 422), иначе — общий.
String failureText(Failure f) => switch (f) {
  ServerFailure(:final message?) => message,
  ServerFailure(:final statusCode) => t.portal.cells.errorCode(
    code: statusCode,
  ),
  NetworkFailure() => t.portal.login.errorNetwork,
  _ => t.portal.login.errorUnknown,
};
