import '../../../core/drafts/drafts.dart';

/// Черновик незавершённого сеанса перемещения (P6-04).
///
/// Пустой наследник [Drafts] - чтобы контейнер зависимостей отличал его от черновиков других
/// потоков (ADHOC-71). Главный экран следит по нему за пометкой на плитке. Реализация -
/// `MovementDraftStore` в `data`.
abstract interface class MovementDrafts implements Drafts {}
