import '../../../core/drafts/drafts.dart';

/// Черновик незавершённой приёмки (P4-09): её единственная копия до «Завершить приёмку».
///
/// Пустой наследник [Drafts] - чтобы контейнер зависимостей отличал его от черновиков других
/// потоков (ADHOC-71). Реализация - `ReceiptDraftStore` в `data`.
abstract interface class ReceiptDrafts implements Drafts {}
