import '../../../core/drafts/drafts.dart';

/// Черновик незавершённого прохода «Ввода остатков» (P2-03): единственная копия обхода до
/// «Завершить ввод».
///
/// Пустой наследник [Drafts] - чтобы контейнер зависимостей отличал его от черновиков других
/// потоков (ADHOC-71). По нему же пометка незавершённого прохода на входах в разделы
/// (`PendingPassBadge`). Реализация - `EntryDraftStore` в `data`.
abstract interface class StockEntryDrafts implements Drafts {}
