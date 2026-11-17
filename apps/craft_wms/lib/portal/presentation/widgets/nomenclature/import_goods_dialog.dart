import 'package:flutter/material.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/error/failure.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';
import '../../../domain/import/import_report.dart';
import '../../../domain/nomenclature/nomenclature_repository.dart';
import '../../../../core/web_files/web_file_picker.dart';
import '../settings/access_common.dart';
import '../ui/portal_button.dart';
import '../ui/portal_drop_zone.dart';
import '../ui/portal_modal.dart';

/// Окно «Загрузить из 1С» страницы «Номенклатура склада» (ADHOC-56): выбор `.xls`-выгрузки,
/// загрузка и отчёт импорта. `true` - справочник обновлён, список страницы надо перечитать.
Future<bool> showImportGoodsDialog(BuildContext context) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) => const _ImportGoodsDialog(),
    ) ??
    false;

class _ImportGoodsDialog extends StatefulWidget {
  const _ImportGoodsDialog();

  @override
  State<_ImportGoodsDialog> createState() => _ImportGoodsDialogState();
}

class _ImportGoodsDialogState extends State<_ImportGoodsDialog> {
  final _repo = getIt<NomenclatureRepository>();

  /// Выбранный файл: имя и байты (на вебе файла на диске нет - работаем с байтами).
  String? _filename;
  List<int>? _bytes;

  bool _uploading = false;
  ImportReport? _report;
  String? _error;

  /// Выбор `.xls`-файла через диалог браузера; прежний отчёт и ошибка сбрасываются.
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

  /// Загрузить выбранный файл; отказ сервера по файлу (нет колонки, не читается) - его текстом.
  Future<void> upload() async {
    final bytes = _bytes;
    final filename = _filename;
    if (bytes == null || filename == null || _uploading) return;
    setState(() {
      _uploading = true;
      _error = null;
    });
    final res = await _repo.importGoods(bytes: bytes, filename: filename);
    if (!mounted) return;
    setState(() {
      _uploading = false;
      res.fold(
        (f) => _error = t.portal.nomenclature.error(message: _text(f)),
        (r) => _report = r,
      );
    });
  }

  /// Закрыть окно; после загрузки - с сигналом перечитать список.
  void close() => Navigator.of(context).pop(_report != null);

  String _text(Failure f) => switch (f) {
    ServerFailure(:final message?) => message,
    ServerFailure(:final statusCode) => 'HTTP $statusCode',
    NetworkFailure() => t.portal.login.errorNetwork,
    _ => t.portal.login.errorUnknown,
  };

  @override
  Widget build(BuildContext context) {
    final report = _report;
    return PortalModal(
      title: t.portal.nomenclature.title,
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            t.portal.nomenclature.description,
            style: RegularTextStyles().regularInter13.copyWith(
              color: AppColors.kTextMuted,
            ),
          ),
          portalFieldGap,
          PortalDropZone(
            prompt: t.portal.nomenclature.uploadPrompt,
            hint: t.portal.nomenclature.dropHint,
            filename: _filename,
            onTap: _uploading ? null : pickFile,
          ),
          if (_error != null) ...[portalFieldGap, AccessError(_error!)],
          if (report != null) ...[portalFieldGap, _Report(report: report)],
        ],
      ),
      actions: [
        PortalButton(
          label: t.portal.common.close,
          kind: PortalButtonKind.plain,
          onPressed: close,
        ),
        if (report == null)
          PortalButton(
            label: t.portal.nomenclature.upload,
            icon: Icons.upload,
            kind: PortalButtonKind.primary,
            busy: _uploading,
            // Файл ещё не выбран - кнопка открывает выбор, как и сама зона.
            onPressed: _bytes == null ? pickFile : upload,
          ),
      ],
    );
  }
}

/// Отчёт импорта: счётчики и пропущенные строки - каждый факт своей строкой.
class _Report extends StatelessWidget {
  const _Report({required this.report});

  final ImportReport report;

  @override
  Widget build(BuildContext context) {
    final n = t.portal.nomenclature;
    final muted = RegularTextStyles().regularInter13.copyWith(
      color: AppColors.kTextMuted,
    );
    Widget stat(String label, int value) => Row(
      children: [
        Expanded(child: Text(label, style: muted)),
        Text(
          '$value',
          style: SemiboldTextStyles().semiboldInter13.copyWith(
            color: AppColors.kTextMain,
          ),
        ),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          n.reportTitle,
          style: SemiboldTextStyles().semiboldInter13.copyWith(
            color: AppColors.kBadgeSuccessText,
          ),
        ),
        AppBoxes.kHeight8,
        stat(n.created, report.goodsCreated),
        stat(n.updated, report.goodsUpdated),
        stat(n.groups, report.groups),
        stat(n.suppliers, report.suppliers),
        if (report.skipped.isNotEmpty) ...[
          AppBoxes.kHeight12,
          Text(
            n.skippedTitle(count: report.skipped.length),
            style: SemiboldTextStyles().semiboldInter13.copyWith(
              color: AppColors.kBadgeWarningText,
            ),
          ),
          AppBoxes.kHeight4,
          for (final row in report.skipped)
            Text(
              n.skippedRow(row: row.row, message: row.message),
              style: muted,
            ),
        ],
      ],
    );
  }
}
