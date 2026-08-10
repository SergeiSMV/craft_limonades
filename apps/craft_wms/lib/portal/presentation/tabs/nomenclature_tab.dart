import 'package:flutter/material.dart';

import '../../../core/constants/app_boxes.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_insets.dart';
import '../../../core/constants/app_sizes.dart';
import '../../../core/di/injection.dart';
import '../../../core/error/failure.dart';
import '../../../core/gen/strings.g.dart';
import '../../data/import_report.dart';
import '../../data/nomenclature_repository.dart';
import '../../data/web_file_picker.dart';
import 'widgets/upload_widgets.dart';

/// Вкладка «Номенклатура» — единственная рабочая в MVP портала (P1-04 готов на бэке).
/// По макету: карточка с зоной загрузки (клик = выбор `.xls`), ниже — отчёт импорта.
class NomenclatureTab extends StatefulWidget {
  const NomenclatureTab({super.key});

  @override
  State<NomenclatureTab> createState() => _NomenclatureTabState();
}

class _NomenclatureTabState extends State<NomenclatureTab> {
  final _repo = getIt<NomenclatureRepository>();

  /// Выбранный файл: имя и байты (на вебе файла на диске нет — работаем с байтами).
  String? _filename;
  List<int>? _bytes;

  bool _hovering = false;
  bool _uploading = false;
  ImportReport? _report;
  Failure? _error;

  /// Выбор `.xls`-файла через системный диалог браузера (имя + байты).
  Future<void> pickFile() async {
    final file = await pickFileFromBrowser(accept: '.xls');
    if (file == null || !mounted) return;
    setState(() {
      _filename = file.name;
      _bytes = file.bytes;
      _report = null;
      _error = null;
    });
  }

  /// Загрузка выбранного файла на бэкенд и разбор результата в отчёт/ошибку.
  Future<void> upload() async {
    final bytes = _bytes;
    final filename = _filename;
    if (bytes == null || filename == null || _uploading) return;

    setState(() {
      _uploading = true;
      _report = null;
      _error = null;
    });

    final result = await _repo.importGoods(bytes: bytes, filename: filename);
    if (!mounted) return;
    setState(() {
      _uploading = false;
      result.fold((f) => _error = f, (r) => _report = r);
    });
  }

  /// Текст ошибки: для 422 показываем причину с бэкенда (нет колонки/не читается).
  String _errorText(Failure failure) {
    final message = switch (failure) {
      ServerFailure(:final message, :final statusCode) => message ?? 'HTTP $statusCode',
      NetworkFailure() => t.portal.login.errorNetwork,
      _ => t.portal.login.errorUnknown,
    };
    return t.portal.nomenclature.error(message: message);
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: AppInsets.all32,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: AppSizes.kContentMaxWidth),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Card(
                child: Padding(
                  padding: AppInsets.all32,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        t.portal.nomenclature.title,
                        style: const TextStyle(fontSize: AppSizes.kText24, fontWeight: FontWeight.w600),
                      ),
                      AppBoxes.kHeight8,
                      Text(
                        t.portal.nomenclature.description,
                        style: const TextStyle(fontSize: AppSizes.kText14, color: AppColors.kTextMuted),
                      ),
                      AppBoxes.kHeight24,
                      PortalUploadZone(
                        filename: _filename,
                        hovering: _hovering,
                        onTap: _uploading ? null : pickFile,
                        onHover: (v) => setState(() => _hovering = v),
                        prompt: t.portal.nomenclature.uploadPrompt,
                        hint: t.portal.nomenclature.uploadHint,
                        badge: t.portal.nomenclature.uploadBadge,
                      ),
                      if (_filename != null && !_uploading) ...[
                        AppBoxes.kHeight24,
                        Align(
                          alignment: Alignment.centerRight,
                          child: FilledButton.icon(
                            onPressed: upload,
                            icon: const Icon(Icons.upload_file, size: AppSizes.kIcon18),
                            label: Text(t.portal.nomenclature.upload),
                          ),
                        ),
                      ],
                      if (_uploading) ...[
                        AppBoxes.kHeight24,
                        Row(
                          children: [
                            const SizedBox(
                              width: AppSizes.kIcon24,
                              height: AppSizes.kIcon24,
                              child: CircularProgressIndicator(strokeWidth: AppSizes.kIcon2),
                            ),
                            AppBoxes.kWidth12,
                            Text(t.portal.nomenclature.uploading),
                          ],
                        ),
                      ],
                      if (_error != null) ...[
                        AppBoxes.kHeight24,
                        Text(
                          _errorText(_error!),
                          style: const TextStyle(color: AppColors.kDanger, fontSize: AppSizes.kText15),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              if (_report != null) ...[
                AppBoxes.kHeight24,
                _ReportCard(report: _report!),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Карточка результата импорта: счётчики + список пропущенных строк.
class _ReportCard extends StatelessWidget {
  const _ReportCard({required this.report});

  final ImportReport report;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: AppInsets.all32,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.check_circle, color: AppColors.kBadgeSuccessText),
                AppBoxes.kWidth8,
                Text(
                  t.portal.nomenclature.reportTitle,
                  style: const TextStyle(fontSize: AppSizes.kText20, fontWeight: FontWeight.w600),
                ),
              ],
            ),
            AppBoxes.kHeight16,
            PortalStatRow(label: t.portal.nomenclature.created, value: report.goodsCreated),
            PortalStatRow(label: t.portal.nomenclature.updated, value: report.goodsUpdated),
            PortalStatRow(label: t.portal.nomenclature.groups, value: report.groups),
            PortalStatRow(label: t.portal.nomenclature.suppliers, value: report.suppliers),
            if (report.skipped.isNotEmpty) ...[
              AppBoxes.kHeight16,
              Text(
                t.portal.nomenclature.skippedTitle(count: report.skipped.length),
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  color: AppColors.kBadgeWarningText,
                ),
              ),
              AppBoxes.kHeight8,
              for (final row in report.skipped)
                Text(
                  t.portal.nomenclature.skippedRow(row: row.row, message: row.message),
                  style: const TextStyle(fontSize: AppSizes.kText14, color: AppColors.kTextMuted),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

