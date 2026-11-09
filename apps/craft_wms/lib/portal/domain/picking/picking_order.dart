import 'dart:typed_data';

import 'package:either_dart/either.dart';

import '../../../core/error/failure.dart';

/// Статус заказа сборки WMS (P9-02): статус из реестра 1С не берётся.
enum PickingStatus { newOrder, inProgress, picked, shipped }

/// Статус из ответа сервера; незнакомый — «новый»: заказ хотя бы виден в списке.
PickingStatus pickingStatusOf(String v) => switch (v) {
  'in_progress' => PickingStatus.inProgress,
  'picked' => PickingStatus.picked,
  'shipped' => PickingStatus.shipped,
  _ => PickingStatus.newOrder,
};

/// Заказ в списке раздела «Сборка-отгрузка» (P8-03): шапка реестра, статус WMS и пометки,
/// кто держит или собрал, итог плана и факта.
class PickingOrderSummary {
  const PickingOrderSummary({
    required this.id,
    required this.number,
    required this.registryDate,
    required this.invoiceNumber,
    required this.orderNumber,
    required this.orderDate,
    required this.direction,
    required this.client,
    required this.address,
    required this.status,
    required this.isPartial,
    required this.hasUnknown,
    required this.deleted,
    required this.changedAfterShipment,
    required this.assigneeName,
    required this.takenAt,
    required this.pickedByName,
    required this.pickedAt,
    required this.shippedAt,
    required this.lines,
    required this.planQty,
    required this.factQty,
    required this.boxes,
    this.returnLeft = 0,
  });

  final String id;

  /// Номер сборки — «СБ-…» при показе.
  final int number;
  final DateTime registryDate;
  final String invoiceNumber;
  final String orderNumber;
  final DateTime? orderDate;
  final String direction;
  final String client;
  final String address;
  final PickingStatus status;

  /// «Собран частично»: по строке отмечено «не хватает».
  final bool isPartial;

  /// Есть позиции вне номенклатуры: сборка не начинается.
  final bool hasUnknown;

  /// Заказ пропал из реестра своей даты.
  final bool deleted;

  /// Реестр изменил или удалил уже отгруженный заказ.
  final bool changedAfterShipment;

  /// Сколько ещё вернуть на места после правки реестра (P9-07-1); пока не ноль, отгрузка закрыта.
  final double returnLeft;

  /// Кто держит заказ в работе; пусто — заказ не в работе.
  final String assigneeName;
  final DateTime? takenAt;

  /// Кто завершил сборку; пусто — ещё не собирали до конца.
  final String pickedByName;
  final DateTime? pickedAt;
  final DateTime? shippedAt;

  /// Число живых строк плана.
  final int lines;
  final int planQty;

  /// Взято: в сборке и в коробах (возвращённое на место не считается).
  final double factQty;
  final int boxes;

  /// Снять с исполнителя можно только заказ в работе.
  bool get releasable => status == PickingStatus.inProgress;
}

/// Пик строки: партия, откуда, в какой короб, сколько, марки ЧЗ. [inBox] — товар уже в коробе
/// отгрузки; иначе «в сборке» — числится в ячейке-источнике.
class PickingFact {
  const PickingFact({
    required this.batchDate,
    required this.cellAddress,
    required this.boxSeq,
    required this.qty,
    required this.inBox,
    required this.pickedBy,
    required this.pickedAt,
    required this.marks,
  });

  final DateTime batchDate;
  final String cellAddress;
  final int boxSeq;
  final double qty;
  final bool inBox;
  final String pickedBy;
  final DateTime pickedAt;
  final List<String> marks;
}

/// Строка плана заказа и факт по ней.
class PickingOrderLine {
  const PickingOrderLine({
    required this.lineNo,
    required this.goodCode,
    required this.goodName,
    required this.uom,
    required this.czMarked,
    required this.batchDate,
    required this.registryCell,
    required this.cellAddress,
    required this.planQty,
    required this.factQty,
    required this.removed,
    required this.shortage,
    required this.facts,
  });

  final int lineNo;
  final String goodCode;
  final String goodName;
  final String uom;
  final bool czMarked;

  /// Партия реестра; `null` — любая (FEFO).
  final DateTime? batchDate;

  /// Ячейка реестра как в файле и найденная в WMS (пусто — не нашлась или не задана).
  final String registryCell;
  final String cellAddress;
  final int planQty;
  final double factQty;

  /// Строка убрана повторной загрузкой реестра.
  final bool removed;

  /// Кладовщик отметил «не хватает».
  final bool shortage;
  final List<PickingFact> facts;

  /// Все марки строки — по пикам.
  List<String> get marks => [for (final f in facts) ...f.marks];
}

/// Короб отгрузки заказа: «короб N»; [shippedAt] — ярлык отсканирован на отгрузке.
class PickingBoxInfo {
  const PickingBoxInfo({required this.seq, required this.shippedAt});

  final int seq;
  final DateTime? shippedAt;
}

/// Правка заказа повторной загрузкой реестра.
class PickingOrderChange {
  const PickingOrderChange({
    required this.kind,
    required this.goodCode,
    required this.goodName,
    required this.batchDate,
    required this.oldQty,
    required this.newQty,
    required this.orderStatus,
    required this.at,
  });

  /// line_added, line_removed, qty_changed, order_deleted, order_restored.
  final String kind;
  final String goodCode;
  final String goodName;
  final DateTime? batchDate;
  final int? oldQty;
  final int? newQty;

  /// Статус заказа в момент правки: что с ней делали.
  final PickingStatus orderStatus;
  final DateTime at;
}

/// Событие журнала заказа (P9-07): взял, отказался, снят старшим, перехватил зависший,
/// завершил, дособор, отгрузил. [prevName] - у кого перехватили или с кого сняли; [boxes] и
/// [qty] - итог завершения и отгрузки.
class PickingOrderEvent {
  const PickingOrderEvent({
    required this.kind,
    required this.userName,
    required this.prevName,
    required this.boxes,
    required this.qty,
    required this.at,
  });

  /// taken, taken_over, released, released_by_lead, completed, reopened, shipped.
  final String kind;
  final String userName;
  final String prevName;
  final int? boxes;
  final double? qty;
  final DateTime at;
}

/// Заказ в окне деталей: шапка, строки план/факт, короба, правки реестра, журнал событий.
class PickingOrderDetail {
  const PickingOrderDetail({
    required this.order,
    required this.lines,
    required this.boxes,
    required this.changes,
    this.events = const [],
  });

  final PickingOrderSummary order;
  final List<PickingOrderLine> lines;
  final List<PickingBoxInfo> boxes;
  final List<PickingOrderChange> changes;
  final List<PickingOrderEvent> events;
}

/// Выгрузка Excel: байты и имя файла от сервера.
typedef PickingExport = ({Uint8List bytes, String filename});

/// Контракт раздела «Сборка-отгрузка» в портале (P8-03). Реализация — `data`.
abstract interface class PickingOrdersRepository {
  /// Заказы на дату накладной; удалённые в 1С — в конце, с пометкой.
  Future<Either<Failure, List<PickingOrderSummary>>> orders(DateTime date);

  /// Заказ для окна деталей.
  Future<Either<Failure, PickingOrderDetail>> order(String id);

  /// Снять заказ с исполнителя: снова «новый», собранное остаётся в коробах.
  Future<Either<Failure, void>> release(String id);

  /// Все заказы даты файлом на момент нажатия.
  Future<Either<Failure, PickingExport>> export(DateTime date);
}
