import 'package:flutter/material.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';
import '../../../data/cells_repository.dart';
import '../../../data/import_report.dart';
import '../../../data/web_file_picker.dart';
import '../settings/access_common.dart';
import '../ui/portal_badge.dart';
import '../ui/portal_button.dart';
import '../ui/portal_card.dart';
import '../ui/portal_drop_zone.dart';
import '../ui/portal_modal.dart';
import 'cells_controller.dart';

/// Окно «Загрузка ячеек» (ADHOC-57): `.xlsx` в формате rack_labels - выбор файла, формат,
/// загрузка и отчёт. `true` - ячейки обновлены, страницу надо перечитать.
Future<bool> showCellsImportDialog(BuildContext context) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) => const _ImportDialog(),
    ) ??
    false;

class _ImportDialog extends StatefulWidget {
  const _ImportDialog();

  @override
  State<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<_ImportDialog> {
  final _repo = getIt<CellsRepository>();

  String? _filename;
  List<int>? _bytes;
  bool _uploading = false;
  CellsImportReport? _report;
  String? _error;

  /// Выбор `.xlsx` в браузере; прежние отчёт и ошибка сбрасываются.
  Future<void> pickFile() async {
    final file = await pickFileFromBrowser(accept: '.xlsx');
    if (file == null || !mounted) return;
    setState(() {
      _filename = file.name;
      _bytes = file.bytes;
      _report = null;
      _error = null;
    });
  }

  /// Загрузить файл; отказ по файлу (нет листа, нет колонки) - текстом сервера.
  Future<void> upload() async {
    final bytes = _bytes, filename = _filename;
    if (bytes == null || filename == null || _uploading) return;
    setState(() {
      _uploading = true;
      _error = null;
    });
    final res = await _repo.importCells(bytes: bytes, filename: filename);
    if (!mounted) return;
    setState(() {
      _uploading = false;
      res.fold(
        (f) =>
            _error = t.portal.cells.importDialog.error(message: failureText(f)),
        (r) => _report = r,
      );
    });
  }

  /// Закрыть; после загрузки - с сигналом перечитать страницу.
  void close() => Navigator.of(context).pop(_report != null);

  @override
  Widget build(BuildContext context) {
    final s = t.portal.cells.importDialog;
    final report = _report;
    final muted = RegularTextStyles().regularInter12.copyWith(
      color: AppColors.kTextMuted,
    );
    return PortalModal(
      title: s.title,
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (report != null)
            _Report(report: report, filename: _filename ?? '')
          else ...[
            PortalDropZone(
              prompt: s.prompt,
              hint: s.hint,
              filename: _filename,
              onTap: _uploading ? null : pickFile,
            ),
            if (_error != null) ...[portalFieldGap, AccessError(_error!)],
            portalFieldGap,
            PortalFieldLabel(s.format),
            const _Format(),
            portalFieldGap,
            Text(s.note, style: muted),
          ],
        ],
      ),
      actions: [
        PortalButton(
          label: t.portal.common.close,
          kind: report == null
              ? PortalButtonKind.plain
              : PortalButtonKind.primary,
          onPressed: close,
        ),
        if (report == null)
          PortalButton(
            label: s.upload,
            icon: Icons.upload,
            kind: PortalButtonKind.primary,
            busy: _uploading,
            // Файл не выбран - кнопка открывает выбор, как и сама зона.
            onPressed: _bytes == null ? pickFile : upload,
          ),
      ],
    );
  }
}

/// Формат файла: листы и колонки rack_labels.
class _Format extends StatelessWidget {
  const _Format();

  @override
  Widget build(BuildContext context) {
    final s = t.portal.cells.importDialog;
    final head = SemiboldTextStyles().semiboldInter12.copyWith(
      color: AppColors.kTextMuted,
    );
    Widget sheet(String text) => Container(
      color: AppColors.kPopoverBg,
      padding: AppInsets.choice,
      child: Text(text, style: head),
    );
    Widget row(String key, String value) => Padding(
      padding: AppInsets.choice,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: AppSizes.kGoodCardLabel,
            child: Text(
              key,
              style: SemiboldTextStyles().semiboldInter12.copyWith(
                color: AppColors.kTextMain,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: RegularTextStyles().regularInter12.copyWith(
                color: AppColors.kTextSecondary,
              ),
            ),
          ),
        ],
      ),
    );
    return PortalCard(
      children: [
        sheet(s.sheetCells),
        row('cell_id', s.cellId),
        row('rack_id', s.rackId),
        row('size', s.size),
        row('arrow', s.arrow),
        row('barcode', s.barcode),
        row('side_card', s.sideCardCell),
        row('barcode_value, copies, print', s.optional),
        sheet(s.sheetRacks),
        row('rack_id', s.rackIdRacks),
        row('side_card', s.sideCard),
      ],
    );
  }
}

/// Отчёт загрузки: каждый факт своей подписанной строкой, ниже - пропущенные строки.
class _Report extends StatelessWidget {
  const _Report({required this.report, required this.filename});

  final CellsImportReport report;
  final String filename;

  @override
  Widget build(BuildContext context) {
    final s = t.portal.cells.importDialog;
    final muted = RegularTextStyles().regularInter13.copyWith(
      color: AppColors.kTextMuted,
    );
    final bold = SemiboldTextStyles().semiboldInter13.copyWith(
      color: AppColors.kTextMain,
    );
    Widget fact(String label, String value) => Padding(
      padding: AppInsets.v2,
      child: Row(
        children: [
          Expanded(child: Text(label, style: muted)),
          Text(value, style: bold),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            PortalBadge(s.done, tone: PortalBadgeTone.success),
            AppBoxes.kWidth8,
            Expanded(
              child: Text(
                filename,
                style: muted,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        AppBoxes.kHeight12,
        fact(s.warehouse, report.warehouse),
        fact(s.cellsCreated, '${report.cellsCreated}'),
        fact(s.cellsUpdated, '${report.cellsUpdated}'),
        fact(s.racksCreated, '${report.racksCreated}'),
        fact(s.racksUpdated, '${report.racksUpdated}'),
        fact(s.skipped, '${report.skipped.length}'),
        if (report.skipped.isNotEmpty) ...[
          AppBoxes.kHeight8,
          for (final r in report.skipped)
            Text(
              s.skippedRow(row: r.row, message: r.message),
              style: RegularTextStyles().regularInter12.copyWith(
                color: AppColors.kBadgeWarningText,
              ),
            ),
        ],
      ],
    );
  }
}
