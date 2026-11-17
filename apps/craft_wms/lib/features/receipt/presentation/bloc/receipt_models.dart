import 'package:freezed_annotation/freezed_annotation.dart';

import '../../../../core/load_unit/box_code.dart';
import '../../../../core/printer/load_unit_label.dart';
import '../../../cz/domain/cz_intake.dart';
import '../../../stock/domain/catalog_models.dart';

part 'receipt_models.freezed.dart';
part 'receipt_models.g.dart';

/// Короб (грузовая единица), собранный в этой приёмке.
///
/// [cell] закрепляется в момент создания короба и больше не меняется: короб не может лежать
/// в двух местах, и сервер отклонил бы документ, где строки одного короба указывают разные
/// ячейки. Отклонение пришло бы уже после разгрузки - поэтому противоречие исключено здесь,
/// конструкцией, а не проверкой на финале. `null` - ячейка приёмки по умолчанию.
///
/// [czCode] - короб «Честного знака» (`00`+SSCC, CZ-05): ГЕ без нашего ярлыка, состав - из ЧЗ,
/// кладовщик выбирает только ячейку. Идентификатор ГЕ ему всё равно выдаёт терминал.
@freezed
abstract class ReceiptBox with _$ReceiptBox {
  const ReceiptBox._();

  const factory ReceiptBox({required String id, Cell? cell, String? czCode}) =
      _ReceiptBox;

  factory ReceiptBox.fromJson(Map<String, dynamic> json) =>
      _$ReceiptBoxFromJson(json);

  /// Короб ЧЗ: состав закрыт, ярлык не нужен.
  bool get isCz => czCode != null;

  /// Короткий код, под которым кладовщик видит короб: с ярлыка - «AB12 CD34», у короба ЧЗ -
  /// хвост SSCC с этикетки поставщика, тоже двумя четвёрками.
  String get shortCode {
    final cz = czCode;
    if (cz == null) return LoadUnitLabel(id).shortCodeFormatted;
    return czBoxTail(cz);
  }
}

/// Документ поставщика, по которому пришёл товар (ADHOC-23): номер накладной и её дата.
///
/// Обязателен: без него приёмка не начинается и не завершается. Накладной без номера ставят
/// «б/н». Дата хранится так, как её видит кладовщик (дд.мм.гггг), в операцию уходит DD-MM-YYYY.
@freezed
abstract class ReceiptDoc with _$ReceiptDoc {
  const ReceiptDoc._();

  const factory ReceiptDoc({required String number, required String date}) =
      _ReceiptDoc;

  factory ReceiptDoc.fromJson(Map<String, dynamic> json) =>
      _$ReceiptDocFromJson(json);

  /// Дата в транспортном виде DD-MM-YYYY - как у дат партий.
  String get transportDate => date.replaceAll('.', '-');
}

/// Строка приёмки: товар, партия (дата выпуска), количество, короб и ячейка.
///
/// Грань - (товар, дата, короб, ячейка), та же, что у строки документа на сервере: повторный
/// скан той же позиции увеличивает количество, другой короб или другая ячейка - новая строка.
/// [boxId] пуст - товар принят штучно (россыпью); [cell] пуста - ячейка по умолчанию.
@freezed
abstract class ReceiptLineDraft with _$ReceiptLineDraft {
  const ReceiptLineDraft._();

  const factory ReceiptLineDraft({
    required Good good,
    required String productionDate, // дд.мм.гггг (в UI); в API - DD-MM-YYYY
    required double qty,
    String? boxId,
    Cell? cell,

    /// Марки ЧЗ строки (CZ-05): единицы, принятые сканом марки или в составе короба ЧЗ.
    @Default(<CzMarkDraft>[]) List<CzMarkDraft> marks,
  }) = _ReceiptLineDraft;

  factory ReceiptLineDraft.fromJson(Map<String, dynamic> json) =>
      _$ReceiptLineDraftFromJson(json);

  /// Сколько марок строки расходятся с ЧЗ - уйдут в «Изолятор».
  int get discrepancies => marks.where((m) => m.discrepancy != null).length;

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
