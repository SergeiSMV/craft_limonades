import 'package:dio/dio.dart';
import 'package:either_dart/either.dart';
import 'package:injectable/injectable.dart';

import '../../core/constants/api_constants.dart';
import '../../core/error/failure.dart';

/// Что загрузка реестра делает с заказом (P8-02).
enum RegistryOrderKind { added, unchanged, changed, deleted, restored }

RegistryOrderKind _kind(String v) => switch (v) {
  'new' => RegistryOrderKind.added,
  'changed' => RegistryOrderKind.changed,
  'deleted' => RegistryOrderKind.deleted,
  'restored' => RegistryOrderKind.restored,
  _ => RegistryOrderKind.unchanged,
};

/// Строка плана в предпросмотре: товар, партия, количество, ячейка реестра и подсветка.
class RegistryLine {
  const RegistryLine({
    required this.goodCode,
    required this.goodName,
    required this.known,
    required this.batchDate,
    required this.qty,
    required this.cell,
    required this.cellFound,
    required this.available,
    required this.shortage,
  });

  factory RegistryLine.fromJson(Map<String, dynamic> j) => RegistryLine(
    goodCode: j['good_code'] as String,
    goodName: j['good_name'] as String,
    known: j['known'] as bool,
    batchDate: _date(j['batch_date']),
    qty: j['qty'] as int,
    cell: j['cell'] as String,
    cellFound: j['cell_found'] as bool,
    available: (j['available'] as num?)?.toDouble(),
    shortage: j['shortage'] as bool,
  );

  final String goodCode;
  final String goodName;

  /// Код найден в справочнике.
  final bool known;
  final DateTime? batchDate;
  final int qty;

  /// Ячейка из реестра как в файле; пусто - без ячейки.
  final String cell;

  /// Ячейка с таким адресом есть в WMS.
  final bool cellFound;

  /// Остаток для сборки по товару и партии; null - не сверялся (товар вне справочника, заказ
  /// уже собран или отгружен).
  final double? available;

  /// Остатка не хватает на все собирающиеся заказы файла с этой позицией.
  final bool shortage;
}

/// Правка заказа против прошлой загрузки той же даты.
class RegistryChange {
  const RegistryChange({
    required this.kind,
    required this.goodCode,
    required this.goodName,
    required this.batchDate,
    required this.oldQty,
    required this.newQty,
  });

  factory RegistryChange.fromJson(Map<String, dynamic> j) => RegistryChange(
    kind: j['kind'] as String,
    goodCode: j['good_code'] as String? ?? '',
    goodName: j['good_name'] as String? ?? '',
    batchDate: _date(j['batch_date']),
    oldQty: j['old_qty'] as int?,
    newQty: j['new_qty'] as int?,
  );

  /// line_added, line_removed, qty_changed, order_deleted, order_restored.
  final String kind;
  final String goodCode;
  final String goodName;
  final DateTime? batchDate;
  final int? oldQty;
  final int? newQty;
}

/// Заказ в предпросмотре.
class RegistryOrder {
  const RegistryOrder({
    required this.kind,
    required this.number,
    required this.status,
    required this.invoiceNumber,
    required this.orderNumber,
    required this.client,
    required this.address,
    required this.hasUnknown,
    required this.hasShortage,
    required this.shipped,
    required this.reopen,
    required this.lines,
    required this.changes,
  });

  factory RegistryOrder.fromJson(Map<String, dynamic> j) => RegistryOrder(
    kind: _kind(j['kind'] as String),
    number: j['number'] as int?,
    status: j['status'] as String,
    invoiceNumber: j['invoice_number'] as String,
    orderNumber: j['order_number'] as String,
    client: j['client'] as String,
    address: j['address'] as String,
    hasUnknown: j['has_unknown'] as bool,
    hasShortage: j['has_shortage'] as bool,
    shipped: j['shipped'] as bool,
    reopen: j['reopen'] as bool,
    lines: [
      for (final l in j['lines'] as List)
        RegistryLine.fromJson(l as Map<String, dynamic>),
    ],
    changes: [
      for (final c in j['changes'] as List)
        RegistryChange.fromJson(c as Map<String, dynamic>),
    ],
  );

  final RegistryOrderKind kind;

  /// Номер сборки («СБ-…») уже загруженного заказа; у нового - null.
  final int? number;

  /// Статус WMS до загрузки: new, in_progress, picked, shipped.
  final String status;
  final String invoiceNumber;
  final String orderNumber;
  final String client;
  final String address;
  final bool hasUnknown;
  final bool hasShortage;

  /// Заказ отгружен: товар не двигается, только пометка «изменён в 1С после отгрузки».
  final bool shipped;

  /// Собранный заказ уйдёт на дособор.
  final bool reopen;
  final List<RegistryLine> lines;
  final List<RegistryChange> changes;
}

/// Отклонённая строка файла.
class RegistryRowError {
  const RegistryRowError({required this.row, required this.message});

  final int row;
  final String message;
}

/// Предпросмотр (и итог) загрузки реестра.
class RegistryPreview {
  const RegistryPreview({
    required this.loadId,
    required this.date,
    required this.counts,
    required this.orders,
    required this.unknownCodes,
    required this.errors,
  });

  factory RegistryPreview.fromJson(Map<String, dynamic> j) {
    final c = j['counts'] as Map<String, dynamic>;
    return RegistryPreview(
      loadId: j['load_id'] as String?,
      date: DateTime.parse(j['date'] as String),
      counts: {
        RegistryOrderKind.added: c['new'] as int,
        RegistryOrderKind.unchanged: c['unchanged'] as int,
        RegistryOrderKind.changed: c['changed'] as int,
        RegistryOrderKind.deleted: c['deleted'] as int,
        RegistryOrderKind.restored: c['restored'] as int,
      },
      orders: [
        for (final o in j['orders'] as List)
          RegistryOrder.fromJson(o as Map<String, dynamic>),
      ],
      unknownCodes: [for (final s in j['unknown_codes'] as List) s as String],
      errors: [
        for (final e in j['errors'] as List)
          RegistryRowError(
            row: (e as Map<String, dynamic>)['row'] as int,
            message: e['message'] as String,
          ),
      ],
    );
  }

  /// Id записанной загрузки; у предпросмотра - null.
  final String? loadId;

  /// Дата накладных файла - дата сборки.
  final DateTime date;
  final Map<RegistryOrderKind, int> counts;
  final List<RegistryOrder> orders;
  final List<String> unknownCodes;
  final List<RegistryRowError> errors;
}

DateTime? _date(Object? v) => v == null ? null : DateTime.parse(v as String);

/// Сборка-отгрузка в портале (P8-02): предпросмотр и загрузка «Реестра» 1С.
/// Слой data: изолирует HTTP от UI, отдаёт `Either<Failure, RegistryPreview>`.
@lazySingleton
class PickingRepository {
  PickingRepository(this._dio);

  final Dio _dio;

  /// Предпросмотр: сервер разбирает файл и сверяет с заказами той же даты, ничего не записывая.
  Future<Either<Failure, RegistryPreview>> preview({
    required List<int> bytes,
    required String filename,
  }) => _send(ApiConst.pickingRegistryPreview, bytes, filename);

  /// Загрузка после подтверждения: тот же файл, сверка повторяется по свежему состоянию.
  Future<Either<Failure, RegistryPreview>> load({
    required List<int> bytes,
    required String filename,
  }) => _send(ApiConst.pickingRegistryLoad, bytes, filename);

  Future<Either<Failure, RegistryPreview>> _send(
    String path,
    List<int> bytes,
    String filename,
  ) async {
    try {
      final form = FormData.fromMap({
        'file': MultipartFile.fromBytes(bytes, filename: filename),
      });
      final resp = await _dio.post<Map<String, dynamic>>(path, data: form);
      return Right(RegistryPreview.fromJson(resp.data!));
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code == null) return const Left(Failure.network());
      // 422 - файл не принят (нет листа или колонки, несколько дат): текст сервера показываем.
      final msg = (e.response?.data is Map)
          ? (e.response!.data['error'] as String?)
          : null;
      return Left(Failure.server(code, code == 422 ? msg : null));
    } catch (_) {
      return const Left(Failure.unknown());
    }
  }
}
