import 'picking_models.dart';

/// Как свой пик терминала соотносится с последним ответом сервера (P9-06).
///
/// [picked] - пик учитывать поверх ответа: операция ещё в очереди или подтверждена после
/// запроса; [pickPending] - ещё не подтверждена. [unpicked] и [unpickPending] - то же для
/// возврата.
typedef LocalPickState = ({
  bool picked,
  bool pickPending,
  bool unpicked,
  bool unpickPending,
});

/// Пик на экране заказа: с сервера или свой, ещё не учтённый сервером.
class ViewPick {
  const ViewPick({
    required this.pick,
    this.pending = false,
    this.returning = false,
    this.returnPending = false,
    this.local,
  });

  final PickingPick pick;

  /// Пик ещё в очереди - сервер о нём не знает.
  final bool pending;

  /// Пик вернули: возврат в очереди или подтверждён после запроса заказа.
  final bool returning;

  /// Возврат ещё в очереди - пик показывается «возвращается»; подтверждённый - не показывается.
  final bool returnPending;

  /// Пик виден на экране.
  bool get visible => !returning || returnPending;

  /// Запись терминала, если пик сделан здесь.
  final LocalPick? local;
}

/// Заказ на экране: ответ сервера, наложенные на него свои пики и возвраты.
///
/// Что: собранное по строкам и в коробах так, как его видит кладовщик прямо сейчас.
/// Зачем: пик уходит очередью и без связи; ответ сервера о нём ещё не знает, а повторный пик
/// того же товара сверх плана сервер отклонит. Поэтому «взято» считается с очередью.
/// Как: пик терминала добавляется, если его нет среди пиков ответа (сверка по `pick_id`, так
/// что пик, подтверждённый во время запроса, не задвоится); пик ответа с возвратом в очереди
/// вычитается.
class PickingOrderView {
  PickingOrderView({
    required this.order,
    required this.picks,
    this.currentBoxId,
    this.fromCache = false,
  });

  /// Собрать из слепка и состояния своих операций [states] (по `pick_id`).
  factory PickingOrderView.build(
    PickingOrderDraft draft, {
    required Map<String, LocalPickState> states,
    bool fromCache = false,
  }) {
    final order = draft.order;
    final byId = {for (final l in draft.local) l.pick.id: l};
    final serverIds = {for (final p in order.picks) p.id};
    final picks = <ViewPick>[];
    for (final p in order.picks) {
      final local = byId[p.id];
      final st = states[p.id];
      picks.add(
        ViewPick(
          pick: p,
          returning: st != null && st.unpicked,
          returnPending: st != null && st.unpicked && st.unpickPending,
          local: local,
        ),
      );
    }
    for (final l in draft.local) {
      if (serverIds.contains(l.pick.id)) continue;
      final st = states[l.pick.id];
      if (st == null || !st.picked || st.unpicked) continue;
      picks.add(ViewPick(pick: l.pick, pending: st.pickPending, local: l));
    }
    final boxes = order.boxes.map((b) => b.loadUnitId).toSet();
    final current = boxes.contains(draft.currentBoxId)
        ? draft.currentBoxId
        : (order.boxes.isEmpty ? null : order.boxes.last.loadUnitId);
    return PickingOrderView(
      order: order,
      picks: picks,
      currentBoxId: current,
      fromCache: fromCache,
    );
  }

  final PickingOrder order;

  /// Все пики, включая вернутые после запроса заказа: их взятое ещё в ответе сервера.
  final List<ViewPick> picks;

  /// Короб отгрузки, в который идёт пик; `null` - коробов ещё нет.
  final String? currentBoxId;

  /// Заказ из слепка терминала: связи не было.
  final bool fromCache;

  /// Строки, которые собирают: убранные реестром - нет.
  List<PickingLine> get activeLines =>
      order.lines.where((l) => !l.removed).toList();

  /// Видимые пики строки.
  List<ViewPick> picksOf(String lineId) =>
      picks.where((p) => p.visible && p.pick.lineId == lineId).toList();

  /// Видимые пики короба отгрузки.
  List<ViewPick> picksIn(String boxId) =>
      picks.where((p) => p.visible && p.pick.boxId == boxId).toList();

  /// Взято по строке с учётом очереди.
  double taken(PickingLine line) {
    var qty = line.taken;
    for (final p in picks) {
      if (p.pick.lineId != line.id) continue;
      final onServer = order.picks.any((s) => s.id == p.pick.id);
      if (!onServer) qty += p.pick.qty;
      if (onServer && p.returning) qty -= p.pick.qty;
    }
    return qty < 0 ? 0 : qty;
  }

  /// Сколько ещё взять по строке.
  double remaining(PickingLine line) {
    final left = line.planQty - taken(line);
    return left < 0 ? 0 : left;
  }

  /// Строка собрана целиком.
  bool done(PickingLine line) => remaining(line) <= 0;

  /// Номер короба отгрузки по его id; `null` - короба нет в заказе.
  int? boxSeq(String boxId) =>
      order.boxes.where((b) => b.loadUnitId == boxId).firstOrNull?.seq;

  /// Марки, уже взятые по заказу - второй раз их не берут.
  Set<String> get pickedMarks => {
    for (final p in picks)
      if (!p.returning) ...p.pick.marks,
  };
}
