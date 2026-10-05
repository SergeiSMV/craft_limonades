import 'package:injectable/injectable.dart';

import '../../../core/database/app_database.dart';
import '../../../core/database/draft_slot.dart';

/// Хранилище незавершённой приёмки (P4-09).
///
/// Приёмка набирается на терминале целиком и уходит на сервер одной операцией на «Завершить
/// приёмку». До этого её единственная копия — здесь: разгрузка машины не должна пропасть
/// из-за разряда батареи посередине.
@lazySingleton
class ReceiptDraftStore extends DraftSlot {
  ReceiptDraftStore(AppDatabase db) : super(db, 'receipt');
}
