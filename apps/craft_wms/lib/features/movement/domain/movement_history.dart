import 'package:either_dart/either.dart';

import '../../../core/error/failure.dart';
import 'movement_models.dart';

/// История перемещений всего склада (ADHOC-28): вкладка «Завершённые» в разделе
/// «Перемещение». Кладовщик видит, кто и куда дел короб или товар. Только онлайн.

/// Кто перемещал.
class MoveUser {
  const MoveUser({required this.id, required this.fullName});

  final String id;
  final String fullName;
}

/// Запись ленты - перемещение целиком: кто, когда, сколько коробов и строк товара.
class MoveRecord {
  const MoveRecord({
    required this.id,
    required this.kind,
    required this.postedAt,
    required this.executor,
    required this.loadUnits,
    required this.goods,
    this.number = 0,
  });

  final String id;

  /// Номер операции в счётчике своего вида (ADHOC-55): ПМ-… или ПП-…; 0 - сервер без номеров.
  final int number;

  /// Вид документа: `move` - перемещение, `replenish` - пополнение (заморожено).
  final String kind;

  /// Момент проведения строкой, как его отдал сервер: это и курсор подгрузки, и сервер ждёт
  /// его до наносекунд - перевод в DateTime и обратно их терял бы.
  final String postedAt;
  final MoveUser executor;

  /// Строк «короб целиком».
  final int loadUnits;

  /// Строк товара.
  final int goods;

  /// Момент проведения - для показа и разделителей по дням.
  DateTime get postedAtTime => DateTime.parse(postedAt);
}

/// Запись со строками - в том виде, в каком их видел кладовщик в сеансе: с коробами
/// и перекладыванием внутри ячейки.
class MoveRecordDetail {
  const MoveRecordDetail({required this.record, required this.lines});

  final MoveRecord record;
  final List<MoveLine> lines;
}

/// Фильтр ленты: период по дням терминала и исполнитель. Пустые поля ленту не сужают.
class MoveHistoryQuery {
  const MoveHistoryQuery({this.from, this.to, this.executorId});

  final DateTime? from;
  final DateTime? to;
  final String? executorId;
}

/// Источник истории перемещений. Реализация - `MovementHistoryRepositoryImpl` в `data`.
abstract interface class MovementHistoryRepository {
  /// Страница ленты, свежие сверху. [after] - последняя показанная запись (курсор).
  Future<Either<Failure, List<MoveRecord>>> page({
    required MoveHistoryQuery query,
    MoveRecord? after,
    int limit,
  });

  /// Варианты фильтра по исполнителю - все, кто перемещал.
  Future<Either<Failure, List<MoveUser>>> executors();

  /// Запись со строками.
  Future<Either<Failure, MoveRecordDetail>> record(String id);
}
