import '../../../../core/sync/link_state.dart';

/// Что показывает индикатор в шапке (P2-07).
///
/// Порядок значений — порядок важности: чем ниже, тем настойчивее сигнал.
enum SyncBadge {
  /// Очередь пуста — всё, что кладовщик сделал, лежит на сервере.
  allSent,

  /// Отправка идёт прямо сейчас.
  sending,

  /// Есть неотправленное, и оно уйдёт само, когда связь появится.
  waiting,

  /// Есть операции, отклонённые сервером: сами они не уйдут, нужен человек.
  needsAttention,
}

/// Состояние индикатора синхронизации.
class SyncStatusState {
  const SyncStatusState({
    this.pending = 0,
    this.rejected = 0,
    this.link = LinkState.unknown,
    this.syncing = false,
  });

  /// Сколько операций ждёт отправки.
  final int pending;

  /// Сколько отклонено сервером и требует разбора.
  final int rejected;

  /// Что известно о связи с сервером.
  final LinkState link;

  /// Идёт ли отправка прямо сейчас.
  final bool syncing;

  /// Какой сигнал показывать.
  ///
  /// Отклонённые важнее всего: они не уйдут сами, и пока их не разобрали, «всё отправлено»
  /// было бы неправдой. Отправка важнее ожидания: она объясняет, почему счётчик сейчас меняется.
  SyncBadge get badge {
    if (rejected > 0) return SyncBadge.needsAttention;
    if (syncing) return SyncBadge.sending;
    if (pending > 0) return SyncBadge.waiting;
    return SyncBadge.allSent;
  }

  /// Сколько всего строк в очереди — число на значке.
  int get total => pending + rejected;

  /// Показывать ли пометку «нет связи».
  ///
  /// Только когда она что-то объясняет: при пустой очереди отсутствие связи ни на что не влияет
  /// — отправлять нечего, и тревожить кладовщика незачем. Про `unknown` молчим всегда: обменов
  /// не было, и утверждать нечего.
  bool get showOffline => link == LinkState.offline && total > 0;

  SyncStatusState copyWith({
    int? pending,
    int? rejected,
    LinkState? link,
    bool? syncing,
  }) => SyncStatusState(
    pending: pending ?? this.pending,
    rejected: rejected ?? this.rejected,
    link: link ?? this.link,
    syncing: syncing ?? this.syncing,
  );

  @override
  bool operator ==(Object other) =>
      other is SyncStatusState &&
      other.pending == pending &&
      other.rejected == rejected &&
      other.link == link &&
      other.syncing == syncing;

  @override
  int get hashCode => Object.hash(pending, rejected, link, syncing);
}
