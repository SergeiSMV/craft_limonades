import 'package:craft_wms/core/di/injection.dart';
import 'package:craft_wms/features/stock_entry/data/entry_draft_store.dart';
import 'package:mocktail/mocktail.dart';

class _MockDrafts extends Mock implements EntryDraftStore {}

/// Зарегистрировать пустое хранилище прохода для экранов, где висит [PendingPassBadge].
///
/// Пометка незавершённого прохода стоит на входах в раздел (ADHOC-13), поэтому экран «Остатки»
/// теперь зависит от хранилища слепка. Настоящую drift-базу сюда подключать нельзя: она вешает
/// виджет-тест таймером нулевой длительности на отмене подписки (урок P2-06).
void registerEmptyDraftStore() {
  final drafts = _MockDrafts();
  when(() => drafts.watchHasDraft()).thenAnswer((_) => Stream.value(false));
  if (getIt.isRegistered<EntryDraftStore>()) {
    getIt.unregister<EntryDraftStore>();
  }
  getIt.registerSingleton<EntryDraftStore>(drafts);
}
