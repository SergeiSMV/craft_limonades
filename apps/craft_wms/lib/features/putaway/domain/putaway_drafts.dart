import '../../../core/drafts/drafts.dart';

/// Черновик незавершённого сеанса размещения (P5-03): его единственная копия до «Завершить».
///
/// Пустой наследник [Drafts] - чтобы контейнер зависимостей отличал его от черновиков других
/// потоков (ADHOC-71). Реализация - `PutawayDraftStore` в `data`.
abstract interface class PutawayDrafts implements Drafts {}
