import 'package:freezed_annotation/freezed_annotation.dart';

part 'import_report.freezed.dart';
part 'import_report.g.dart';

/// Итог импорта номенклатуры — ответ `POST /import/goods` (backend `ImportReport`).
/// JsonKey мапит snake_case из JSON на camelCase полей Dart.
@freezed
abstract class ImportReport with _$ImportReport {
  const factory ImportReport({
    @JsonKey(name: 'goods_created') required int goodsCreated,
    @JsonKey(name: 'goods_updated') required int goodsUpdated,
    required int groups,
    required int suppliers,
    @Default(<SkippedRow>[]) List<SkippedRow> skipped,
  }) = _ImportReport;

  factory ImportReport.fromJson(Map<String, dynamic> json) => _$ImportReportFromJson(json);
}

/// Пропущенная строка файла с причиной (backend `importer.RowError`).
/// `row` = 0 у строк, отбракованных не по номеру (напр. товар без единицы измерения).
@freezed
abstract class SkippedRow with _$SkippedRow {
  const factory SkippedRow({
    @Default(0) int row,
    @Default('') String message,
  }) = _SkippedRow;

  factory SkippedRow.fromJson(Map<String, dynamic> json) => _$SkippedRowFromJson(json);
}
