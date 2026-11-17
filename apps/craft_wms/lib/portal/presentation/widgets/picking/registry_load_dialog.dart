import 'package:flutter/material.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/error/failure.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';
import '../../../../core/utils/date_time_format.dart';
import '../../../domain/picking/registry_repository.dart';
import '../../../../core/web_files/web_file_picker.dart';
import '../settings/access_common.dart';
import '../ui/portal_button.dart';
import '../ui/portal_drop_zone.dart';
import '../ui/portal_modal.dart';
import 'registry_order_block.dart';

/// Окно «Загрузить реестр» раздела «Сборка-отгрузка» (P8-02): выбор файла, предпросмотр сверки
/// с уже загруженными заказами той же даты и загрузка после подтверждения. Возвращает итог
/// загрузки; `null` - окно закрыли без загрузки.
Future<RegistryPreview?> showRegistryLoadDialog(BuildContext context) =>
    showDialog<RegistryPreview>(
      context: context,
      builder: (_) => const _RegistryLoadDialog(),
    );

class _RegistryLoadDialog extends StatefulWidget {
  const _RegistryLoadDialog();

  @override
  State<_RegistryLoadDialog> createState() => _RegistryLoadDialogState();
}

class _RegistryLoadDialogState extends State<_RegistryLoadDialog> {
  final _repo = getIt<PickingRepository>();

  String? _filename;
  List<int>? _bytes;

  bool _busy = false;
  RegistryPreview? _preview;
  RegistryPreview? _loaded;
  String? _error;

  /// Выбор файла; прежний предпросмотр и ошибка сбрасываются - они про другой файл.
  Future<void> _pickFile() async {
    final file = await pickFileFromBrowser(accept: '.xlsx');
    if (file == null || !mounted) return;
    setState(() {
      _filename = file.name;
      _bytes = file.bytes;
      _preview = null;
      _error = null;
    });
  }

  /// Предпросмотр: сервер разбирает файл и сверяет его, ничего не записывая.
  Future<void> _check() async {
    final bytes = _bytes, name = _filename;
    if (bytes == null || name == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final res = await _repo.preview(bytes: bytes, filename: name);
    if (!mounted) return;
    setState(() {
      _busy = false;
      res.fold((f) => _error = _text(f), (p) => _preview = p);
    });
  }

  /// Загрузка того же файла после подтверждения.
  Future<void> _load() async {
    final bytes = _bytes, name = _filename;
    if (bytes == null || name == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final res = await _repo.load(bytes: bytes, filename: name);
    if (!mounted) return;
    setState(() {
      _busy = false;
      res.fold((f) => _error = _text(f), (p) => _loaded = p);
    });
  }

  String _text(Failure f) => t.portal.picking.error(
    message: switch (f) {
      ServerFailure(:final message?) => message,
      ServerFailure(:final statusCode) => 'HTTP $statusCode',
      NetworkFailure() => t.portal.login.errorNetwork,
      _ => t.portal.login.errorUnknown,
    },
  );

  @override
  Widget build(BuildContext context) {
    final p = t.portal.picking;
    final shown = _loaded ?? _preview;
    return PortalModal(
      title: p.dialogTitle,
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            p.dialogDescription,
            style: RegularTextStyles().regularInter13.copyWith(
              color: AppColors.kTextMuted,
            ),
          ),
          portalFieldGap,
          PortalDropZone(
            prompt: p.uploadPrompt,
            hint: p.dropHint,
            filename: _filename,
            onTap: _busy || _loaded != null ? null : _pickFile,
          ),
          if (_error != null) ...[portalFieldGap, AccessError(_error!)],
          if (shown != null) ...[
            portalFieldGap,
            _Summary(preview: shown, loaded: _loaded != null),
          ],
        ],
      ),
      actions: [
        PortalButton(
          label: t.portal.common.close,
          kind: PortalButtonKind.plain,
          onPressed: () => Navigator.of(context).pop(_loaded),
        ),
        if (_loaded == null && _preview == null)
          PortalButton(
            label: p.check,
            kind: PortalButtonKind.primary,
            busy: _busy,
            onPressed: _bytes == null ? _pickFile : _check,
          ),
        if (_loaded == null && _preview != null)
          PortalButton(
            label: p.confirm,
            icon: Icons.upload,
            kind: PortalButtonKind.primary,
            busy: _busy,
            onPressed: _load,
          ),
      ],
    );
  }
}

/// Итог сверки: дата, счётчики, нераспознанные коды, отклонённые строки и заказы с правками.
/// Заказы без изменений не показываются - только их число.
class _Summary extends StatelessWidget {
  const _Summary({required this.preview, required this.loaded});

  final RegistryPreview preview;
  final bool loaded;

  @override
  Widget build(BuildContext context) {
    final p = t.portal.picking;
    final muted = RegularTextStyles().regularInter13.copyWith(
      color: AppColors.kTextMuted,
    );
    final strong = SemiboldTextStyles().semiboldInter13.copyWith(
      color: AppColors.kTextMain,
    );
    Widget stat(String label, int value) => Row(
      children: [
        Expanded(child: Text(label, style: muted)),
        Text('$value', style: strong),
      ],
    );
    final counts = preview.counts;
    final orders = preview.orders
        .where((o) => o.kind != RegistryOrderKind.unchanged)
        .toList();
    final unchanged = counts[RegistryOrderKind.unchanged] ?? 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          loaded ? p.loaded : p.date(date: fullDate(preview.date)),
          style: SemiboldTextStyles().semiboldInter13.copyWith(
            color: loaded ? AppColors.kBadgeSuccessText : AppColors.kTextMain,
          ),
        ),
        AppBoxes.kHeight8,
        stat(p.countNew, counts[RegistryOrderKind.added] ?? 0),
        stat(p.countChanged, counts[RegistryOrderKind.changed] ?? 0),
        stat(p.countRestored, counts[RegistryOrderKind.restored] ?? 0),
        stat(p.countDeleted, counts[RegistryOrderKind.deleted] ?? 0),
        stat(p.countUnchanged, unchanged),
        if (preview.unknownCodes.isNotEmpty) ...[
          AppBoxes.kHeight12,
          Text(
            p.unknownTitle(count: preview.unknownCodes.length),
            style: SemiboldTextStyles().semiboldInter13.copyWith(
              color: AppColors.kBadgeWarningText,
            ),
          ),
          AppBoxes.kHeight4,
          Text(preview.unknownCodes.join(', '), style: muted),
        ],
        if (preview.errors.isNotEmpty) ...[
          AppBoxes.kHeight12,
          Text(
            p.errorsTitle(count: preview.errors.length),
            style: SemiboldTextStyles().semiboldInter13.copyWith(
              color: AppColors.kBadgeCriticalText,
            ),
          ),
          AppBoxes.kHeight4,
          for (final e in preview.errors)
            Text(
              p.errorRow(row: e.row, message: e.message),
              style: muted,
            ),
        ],
        if (orders.isNotEmpty) AppBoxes.kHeight12,
        for (var i = 0; i < orders.length; i++) ...[
          if (i > 0) AppBoxes.kHeight8,
          RegistryOrderBlock(order: orders[i]),
        ],
        if (unchanged > 0 && orders.isNotEmpty) ...[
          AppBoxes.kHeight8,
          Text(p.unchangedHidden(count: unchanged), style: muted),
        ],
      ],
    );
  }
}
