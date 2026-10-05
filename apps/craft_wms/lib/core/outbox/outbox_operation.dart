import 'dart:convert';

import '../database/app_database.dart';

/// Тип операции в очереди (P2-03).
///
/// Значения хранятся в базе **строками** (`wire`), а не индексами enum: индекс поедет, стоит
/// вставить новое значение в середину списка, и уже записанные строки станут означать другую
/// операцию. Строка остаётся верной при любой перестановке.
enum OutboxKind {
  /// Привязать штрихкод к товару — `POST /barcodes`.
  bindBarcode('bind_barcode'),

  /// Отвязать штрихкод — `DELETE /barcodes/{code}`.
  unbindBarcode('unbind_barcode'),

  /// Приёмка целиком: документ, его ГЕ, строки и оприходование одной операцией (P4-09).
  ///
  /// Одной, а не цепочкой «открыть → строка → … → оприходовать»: очередь отклонённую операцию
  /// снимает и идёт дальше, и отклонённая строка дала бы оприходование документа без неё.
  receiptSubmit('receipt_submit');

  const OutboxKind(this.wire);

  /// Как значение записано в базе.
  final String wire;

  /// Разобрать значение из базы. `null` — неизвестный тип: строку писала версия приложения
  /// новее текущей (откат сборки), и отправлять её вслепую нельзя.
  static OutboxKind? fromWire(String wire) {
    for (final kind in OutboxKind.values) {
      if (kind.wire == wire) return kind;
    }
    return null;
  }
}

/// Стадия жизни операции.
///
/// `pending → sending → sent` — обычный путь; `sending → pending` — возврат в очередь после
/// неудачной попытки; `rejected` — сервер отказал по существу (например, ШК уже за другим
/// товаром), повторять бессмысленно, нужен разбор человеком (P2-06).
enum OutboxStatus {
  /// Ждёт отправки.
  pending('pending'),

  /// Отправка идёт прямо сейчас. Отдельный статус нужен, чтобы после падения приложения было
  /// видно операции, застрявшие в полёте: их судьба на сервере неизвестна, и решает её дедуп
  /// по `operation_id` (P2-05), а не догадка клиента.
  sending('sending'),

  /// Сервер принял.
  sent('sent'),

  /// Сервер отказал по существу — повтор не поможет.
  rejected('rejected');

  const OutboxStatus(this.wire);

  /// Как значение записано в базе.
  final String wire;

  /// Разобрать значение из базы; `null` — неизвестный статус.
  static OutboxStatus? fromWire(String wire) {
    for (final status in OutboxStatus.values) {
      if (status.wire == wire) return status;
    }
    return null;
  }
}

/// Операция очереди в удобном для домена виде: строка базы с разобранными типом, статусом
/// и телом. Отправщик (P2-04) работает с этим классом, а не с сырой строкой drift.
class OutboxOperation {
  const OutboxOperation({
    required this.seq,
    required this.operationId,
    required this.kind,
    required this.payload,
    required this.status,
    required this.attempts,
    this.lastError,
    required this.createdAt,
    required this.updatedAt,
  });

  /// Собрать из строки базы. Возвращает `null`, если тип или статус не разбираются — такую
  /// строку трогать нельзя (её писала более новая версия приложения).
  static OutboxOperation? fromRow(OutboxRow row) {
    final kind = OutboxKind.fromWire(row.kind);
    final status = OutboxStatus.fromWire(row.status);
    if (kind == null || status == null) return null;
    return OutboxOperation(
      seq: row.seq,
      operationId: row.operationId,
      kind: kind,
      payload: jsonDecode(row.payload) as Map<String, dynamic>,
      status: status,
      attempts: row.attempts,
      lastError: row.lastError,
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
    );
  }

  /// Порядковый номер — он же порядок отправки.
  final int seq;

  /// Ключ идемпотентности (UUID v4).
  final String operationId;

  /// Что за операция.
  final OutboxKind kind;

  /// Тело запроса.
  final Map<String, dynamic> payload;

  /// Стадия жизни.
  final OutboxStatus status;

  /// Сколько раз пытались отправить.
  final int attempts;

  /// Текст последней неудачи.
  final String? lastError;

  final DateTime createdAt;
  final DateTime updatedAt;

  @override
  String toString() =>
      'OutboxOperation(#$seq ${kind.wire} ${status.wire} $operationId)';
}
