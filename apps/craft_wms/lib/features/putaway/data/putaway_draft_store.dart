import 'package:injectable/injectable.dart';

import '../../../core/database/app_database.dart';
import '../../../core/database/draft_slot.dart';

/// Хранилище незавершённого сеанса размещения (P5-03).
///
/// Сеанс набирается на терминале и уходит на сервер одной операцией на «Завершить». До этого
/// его единственная копия — здесь: перенесённые короба не должны пропасть из учёта из-за
/// разряда батареи посередине.
@lazySingleton
class PutawayDraftStore extends DraftSlot {
  PutawayDraftStore(AppDatabase db) : super(db, 'putaway');
}
