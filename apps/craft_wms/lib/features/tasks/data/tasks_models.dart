import 'package:freezed_annotation/freezed_annotation.dart';

part 'tasks_models.freezed.dart';
part 'tasks_models.g.dart';

/// Модели раздела «ЗАДАНИЯ» (P5-02-1) — ответы `GET /tasks…`. Количества приходят строкой
/// (decimal с бэкенда), даты партий — DD-MM-YYYY, как на упаковке.

/// Вид задания. Набор растёт вместе с операциями: P10 — пересчёт.
abstract final class TaskKind {
  static const putaway = 'putaway';

  /// Все виды — варианты фильтра ленты «Завершённые».
  static const all = [putaway];
}

/// Статус задания так, как его видит этот кладовщик: чужое зависшее — «новое».
abstract final class TaskStatus {
  static const fresh = 'new';
  static const inProgress = 'in_progress';
  static const done = 'done';
}

/// Товар позиции задания.
@freezed
abstract class TaskGood with _$TaskGood {
  const factory TaskGood({
    required String id,
    @Default('') String code,
    required String name,
    required String uom,
  }) = _TaskGood;

  factory TaskGood.fromJson(Map<String, dynamic> json) =>
      _$TaskGoodFromJson(json);
}

/// Позиция состава короба: товар, партия, количество.
@freezed
abstract class TaskContent with _$TaskContent {
  const factory TaskContent({
    required TaskGood good,
    @JsonKey(name: 'production_date') required String productionDate,
    required String qty,
  }) = _TaskContent;

  factory TaskContent.fromJson(Map<String, dynamic> json) =>
      _$TaskContentFromJson(json);
}

/// Позиция задания на размещение: короб ([loadUnitId] + [contents]) ЛИБО россыпь ([good] …).
@freezed
abstract class TaskItem with _$TaskItem {
  const factory TaskItem({
    @JsonKey(name: 'line_no') required int lineNo,
    @JsonKey(name: 'load_unit_id') String? loadUnitId,
    @Default(<TaskContent>[]) List<TaskContent> contents,
    TaskGood? good,
    @JsonKey(name: 'production_date') String? productionDate,
    String? qty,
    String? remaining,
    @Default(false) bool placed,
  }) = _TaskItem;

  const TaskItem._();

  /// Позиция — короб целиком.
  bool get isBox => loadUnitId != null;

  factory TaskItem.fromJson(Map<String, dynamic> json) =>
      _$TaskItemFromJson(json);
}

/// Задание для склада.
@freezed
abstract class WarehouseTask with _$WarehouseTask {
  const factory WarehouseTask({
    required String id,
    required int number,
    required String kind,
    required String status,
    @JsonKey(name: 'warehouse_id') required String warehouseId,
    @JsonKey(name: 'receipt_id') String? receiptId,
    @Default('') String supplier,
    @JsonKey(name: 'received_at') DateTime? receivedAt,
    @JsonKey(name: 'assignee_name') @Default('') String assigneeName,
    @JsonKey(name: 'taken_at') DateTime? takenAt,
    @JsonKey(name: 'created_at') required DateTime createdAt,
    @Default(<TaskItem>[]) List<TaskItem> items,
  }) = _WarehouseTask;

  const WarehouseTask._();

  /// Взято этим кладовщиком.
  bool get isMine => status == TaskStatus.inProgress;

  /// Сколько позиций ещё не размещено.
  int get openItems => items.where((i) => !i.placed).length;

  factory WarehouseTask.fromJson(Map<String, dynamic> json) =>
      _$WarehouseTaskFromJson(json);
}

/// Исполнитель задания.
@freezed
abstract class TaskUser with _$TaskUser {
  const factory TaskUser({
    required String id,
    @JsonKey(name: 'full_name') required String fullName,
  }) = _TaskUser;

  factory TaskUser.fromJson(Map<String, dynamic> json) =>
      _$TaskUserFromJson(json);
}

/// Запись ленты «Завершённые» — задание целиком.
@freezed
abstract class CompletedTask with _$CompletedTask {
  const factory CompletedTask({
    required String id,
    required int number,
    required String kind,
    @Default('') String supplier,
    // Строкой, а не DateTime: это и курсор подгрузки, и сервер ждёт его ровно в том виде,
    // в каком отдал, — до наносекунд. Перевод в DateTime и обратно их терял бы.
    @JsonKey(name: 'completed_at') required String completedAt,
    @Default(<TaskUser>[]) List<TaskUser> executors,
    @Default(0) int sessions,
  }) = _CompletedTask;

  const CompletedTask._();

  /// Момент завершения — для показа и разделителей по дате.
  DateTime get completedAtTime => DateTime.parse(completedAt);

  factory CompletedTask.fromJson(Map<String, dynamic> json) =>
      _$CompletedTaskFromJson(json);
}

/// Строка захода: короб или россыпь, откуда → куда.
@freezed
abstract class TaskSessionLine with _$TaskSessionLine {
  const factory TaskSessionLine({
    @JsonKey(name: 'load_unit_id') String? loadUnitId,
    TaskGood? good,
    @JsonKey(name: 'production_date') String? productionDate,
    String? qty,
    required String from,
    required String to,
  }) = _TaskSessionLine;

  factory TaskSessionLine.fromJson(Map<String, dynamic> json) =>
      _$TaskSessionLineFromJson(json);
}

/// Заход по заданию: проведённый сеанс размещения.
@freezed
abstract class TaskSession with _$TaskSession {
  const factory TaskSession({
    @JsonKey(name: 'putaway_id') required String putawayId,
    required TaskUser user,
    @JsonKey(name: 'posted_at') required DateTime postedAt,
    @Default(<TaskSessionLine>[]) List<TaskSessionLine> lines,
  }) = _TaskSession;

  factory TaskSession.fromJson(Map<String, dynamic> json) =>
      _$TaskSessionFromJson(json);
}

/// События журнала задания.
abstract final class TaskEventKind {
  static const created = 'created';
  static const taken = 'taken';
  static const released = 'released';
  static const intercepted = 'intercepted';
  static const session = 'session';
  static const completed = 'completed';
}

/// Запись журнала задания: что случилось, кто, когда. [user] пуст у системных событий.
@freezed
abstract class TaskEvent with _$TaskEvent {
  const factory TaskEvent({
    required String event,
    @Default('') String user,
    @JsonKey(name: 'prev_user') @Default('') String prevUser,
    @JsonKey(name: 'putaway_id') String? putawayId,
    required DateTime at,
  }) = _TaskEvent;

  factory TaskEvent.fromJson(Map<String, dynamic> json) =>
      _$TaskEventFromJson(json);
}

/// Карточка задания с сервера: задание, заходы и журнал событий.
typedef TaskDetailData = ({
  WarehouseTask task,
  List<TaskSession> sessions,
  List<TaskEvent> events,
});

/// Фильтр ленты «Завершённые». Пустые поля ленту не сужают.
@freezed
abstract class CompletedFilter with _$CompletedFilter {
  const factory CompletedFilter({
    DateTime? from,
    DateTime? to,
    TaskUser? executor,
    String? kind,
  }) = _CompletedFilter;

  const CompletedFilter._();

  /// Сколько условий задано — для бейджа на кнопке фильтра.
  int get activeCount =>
      (from != null || to != null ? 1 : 0) +
      (executor != null ? 1 : 0) +
      (kind != null ? 1 : 0);
}
