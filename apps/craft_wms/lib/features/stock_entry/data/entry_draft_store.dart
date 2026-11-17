import 'package:injectable/injectable.dart';

import '../../../core/database/app_database.dart';
import '../../../core/database/draft_slot.dart';

/// Хранилище незавершённого прохода «Ввода остатков» (P2-03).
///
/// Проход копится в памяти и уходит на сервер одним махом на «Завершить ввод» (вариант A,
/// P-FastStart). До P2-03 падение приложения, разряд батареи или выгрузка процесса Android'ом
/// теряли **весь** обход склада - а обход это сотни ячеек и часы работы.
///
/// Ключ `current` остался с тех пор, когда черновик на устройстве был один: уже сохранённые
/// на терминалах проходы лежат под ним, и смена ключа их потеряла бы.
@lazySingleton
class EntryDraftStore extends DraftSlot {
  EntryDraftStore(AppDatabase db) : super(db, 'current');
}
