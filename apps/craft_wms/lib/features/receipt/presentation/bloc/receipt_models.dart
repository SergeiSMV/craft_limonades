import 'package:freezed_annotation/freezed_annotation.dart';

import '../../../../core/printer/load_unit_label.dart';
import '../../../stock/data/catalog_models.dart';

part 'receipt_models.freezed.dart';
part 'receipt_models.g.dart';

/// Короб (грузовая единица), собранный в этой приёмке.
///
/// [cell] закрепляется в момент создания короба и больше не меняется: короб не может лежать
/// в двух местах, и сервер отклонил бы документ, где строки одного короба указывают разные
/// ячейки. Отклонение пришло бы уже после разгрузки — поэтому противоречие исключено здесь,
/// конструкцией, а не проверкой на финале. `null` — ячейка приёмки по умолчанию.
@freezed
abstract class ReceiptBox with _$ReceiptBox {
  const ReceiptBox._();

  const factory ReceiptBox({required String id, Cell? cell}) = _ReceiptBox;

  factory ReceiptBox.fromJson(Map<String, dynamic> json) =>
      _$ReceiptBoxFromJson(json);

  /// Короткий код с ярлыка — «AB12 CD34». Под ним кладовщик видит короб на экране.
  String get shortCode => LoadUnitLabel(id).shortCodeFormatted;
}

/// Строка приёмки: товар, партия (дата выпуска), количество, короб и ячейка.
///
/// Грань — (товар, дата, короб, ячейка), та же, что у строки документа на сервере: повторный
/// скан той же позиции увеличивает количество, другой короб или другая ячейка — новая строка.
/// [boxId] пуст — товар принят штучно (россыпью); [cell] пуста — ячейка по умолчанию.
@freezed
abstract class ReceiptLineDraft with _$ReceiptLineDraft {
  const ReceiptLineDraft._();

  const factory ReceiptLineDraft({
    required Good good,
    required String productionDate, // дд.мм.гггг (в UI); в API — DD-MM-YYYY
    required double qty,
    String? boxId,
    Cell? cell,
  }) = _ReceiptLineDraft;

  factory ReceiptLineDraft.fromJson(Map<String, dynamic> json) =>
      _$ReceiptLineDraftFromJson(json);

  /// Совпадает ли грань строки с заданной.
  bool sameGrain({
    required String goodId,
    required String date,
    required String? boxId,
    required String? cellId,
  }) =>
      good.id == goodId &&
      productionDate == date &&
      this.boxId == boxId &&
      cell?.id == cellId;
}

/// Чем закончилась отправка приёмки.
enum ReceiptOutcome {
  /// Сервер оприходовал приёмку.
  posted,

  /// Связи нет: приёмка стоит в очереди и уйдёт сама. Работа не потеряна.
  queued,

  /// Сервер отказал по существу; приёмка ждёт разбора на экране несинхронизированного.
  rejected,
}
