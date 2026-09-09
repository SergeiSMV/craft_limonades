import 'package:flutter/material.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/error/failure.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../data/inventory_repository.dart';
import '../../../data/web_download.dart';

/// Вкладка «Инвентаризация» (P-FS-09, статусы — P3-02): рабочий список документов «ввод остатков».
/// Оператор скачивает .xlsx, заносит в 1С и отмечает выполненным; необработанные идут сверху.
/// Данные тянутся при открытии; всё admin-only на бэке.
class InventoryTab extends StatefulWidget {
  const InventoryTab({super.key});

  @override
  State<InventoryTab> createState() => _InventoryTabState();
}

class _InventoryTabState extends State<InventoryTab> {
  final _repo = getIt<InventoryRepository>();

  bool _loading = true;
  Failure? _error;
  List<PortalDoc> _docs = const [];
  final _downloading = <String>{}; // id документов, которые сейчас качаются
  final _marking = <String>{}; // id документов, по которым идёт отметка «Выполнено»

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Загрузить список документов.
  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final res = await _repo.listDocuments();
    if (!mounted) return;
    setState(() {
      _loading = false;
      res.fold((f) => _error = f, (docs) => _docs = docs);
    });
  }

  /// Скачать .xlsx документа и сохранить в браузере. Сервер отмечает документ скачанным,
  /// поэтому после успеха список перечитывается — иначе статус на экране отстанет от факта.
  Future<void> _download(PortalDoc doc) async {
    if (_downloading.contains(doc.id)) return;
    setState(() => _downloading.add(doc.id));
    final res = await _repo.downloadReport(doc.id);
    if (!mounted) return;
    setState(() => _downloading.remove(doc.id));
    res.fold(
      (f) => _snack(t.portal.inventory.error(message: _errorText(f))),
      (bytes) {
        downloadBytes(
          bytes: bytes,
          filename: 'vvod-ostatkov-${doc.warehouseCode}.xlsx',
          mime: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        );
        _load();
      },
    );
  }

  /// Отметить документ занесённым в 1С — с подтверждением: вернуть документ в работу нельзя.
  Future<void> _markDone(PortalDoc doc) async {
    if (_marking.contains(doc.id)) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.portal.inventory.confirmTitle),
        content: Text(t.portal.inventory.confirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(t.portal.inventory.confirmNo),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(t.portal.inventory.confirmYes),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _marking.add(doc.id));
    final res = await _repo.markDone(doc.id);
    if (!mounted) return;
    setState(() => _marking.remove(doc.id));
    res.fold(
      (f) => _snack(t.portal.inventory.error(message: _errorText(f))),
      (_) {
        _snack(t.portal.inventory.doneOk);
        _load();
      },
    );
  }

  /// Текст ошибки для снекбара по типу Failure.
  String _errorText(Failure f) => switch (f) {
        ServerFailure(:final message, :final statusCode) => message ?? 'HTTP $statusCode',
        NetworkFailure() => t.portal.login.errorNetwork,
        _ => t.portal.login.errorUnknown,
      };

  /// Показать снекбар с текстом (ошибки скачивания отчёта).
  void _snack(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: AppInsets.all32,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: AppSizes.kContentMaxWidth),
          child: Card(
            child: Padding(
              padding: AppInsets.all32,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    t.portal.inventory.title,
                    style: const TextStyle(fontSize: AppSizes.kText24, fontWeight: FontWeight.w600),
                  ),
                  AppBoxes.kHeight8,
                  Text(
                    t.portal.inventory.description,
                    style: const TextStyle(fontSize: AppSizes.kText14, color: AppColors.kTextMuted),
                  ),
                  AppBoxes.kHeight24,
                  _body(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Тело вкладки по состоянию: индикатор загрузки / пусто / список документов инвентаризации.
  Widget _body() {
    if (_loading) {
      return const Padding(padding: AppInsets.all32, child: Center(child: CircularProgressIndicator()));
    }
    if (_error != null) {
      return Column(
        children: [
          Text(
            t.portal.inventory.error(message: _errorText(_error!)),
            style: const TextStyle(color: AppColors.kDanger, fontSize: AppSizes.kText15),
          ),
          AppBoxes.kHeight16,
          OutlinedButton(onPressed: _load, child: Text(t.portal.inventory.retry)),
        ],
      );
    }
    if (_docs.isEmpty) {
      return Padding(
        padding: AppInsets.all32,
        child: Center(
          child: Text(
            t.portal.inventory.empty,
            style: const TextStyle(color: AppColors.kTextMuted, fontSize: AppSizes.kText15),
          ),
        ),
      );
    }
    return Column(
      children: [
        for (final d in _docs)
          _DocRow(
            doc: d,
            downloading: _downloading.contains(d.id),
            marking: _marking.contains(d.id),
            onDownload: () => _download(d),
            onMarkDone: () => _markDone(d),
          ),
      ],
    );
  }
}

/// Строка документа: склад · дата · число позиций · статус + скачивание и отметка «Выполнено».
class _DocRow extends StatelessWidget {
  const _DocRow({
    required this.doc,
    required this.downloading,
    required this.marking,
    required this.onDownload,
    required this.onMarkDone,
  });

  final PortalDoc doc;
  final bool downloading;
  final bool marking;
  final VoidCallback onDownload;
  final VoidCallback onMarkDone;

  /// Формат даты документа: `дд.мм.гггг чч:мм` в локальной зоне.
  String _date(DateTime dt) {
    final l = dt.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(l.day)}.${two(l.month)}.${l.year} ${two(l.hour)}:${two(l.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final done = doc.status == DocStatus.done;
    return Container(
      margin: AppInsets.bottom8,
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.kBorder),
        borderRadius: BorderRadius.circular(AppSizes.kText12),
      ),
      child: ListTile(
        leading: Icon(done ? Icons.task_alt : Icons.description_outlined),
        title: Row(
          children: [
            Flexible(child: Text('${t.portal.inventory.mark} · ${doc.warehouseName}')),
            AppBoxes.kWidth8,
            _StatusBadge(status: doc.status),
          ],
        ),
        subtitle: Text(
          '${_date(doc.createdAt)} · ${t.portal.inventory.lines(count: doc.linesCount)}',
          style: const TextStyle(fontSize: AppSizes.kText13, color: AppColors.kTextMuted),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Выполненный документ отмечать больше нечем — кнопку убираем, а не гасим:
            // неактивная кнопка предлагала бы действие, которого нет.
            if (!done)
              marking
                  ? const Padding(
                      padding: AppInsets.all8,
                      child: SizedBox(
                        width: AppSizes.kIcon24,
                        height: AppSizes.kIcon24,
                        child: CircularProgressIndicator(strokeWidth: AppSizes.kIcon2),
                      ),
                    )
                  : IconButton(
                      icon: const Icon(Icons.check_circle_outline),
                      tooltip: t.portal.inventory.markDone,
                      onPressed: onMarkDone,
                    ),
            downloading
                ? const Padding(
                    padding: AppInsets.all8,
                    child: SizedBox(
                      width: AppSizes.kIcon24,
                      height: AppSizes.kIcon24,
                      child: CircularProgressIndicator(strokeWidth: AppSizes.kIcon2),
                    ),
                  )
                : IconButton(
                    icon: const Icon(Icons.download),
                    tooltip: t.portal.inventory.download,
                    onPressed: onDownload,
                  ),
          ],
        ),
      ),
    );
  }
}

/// Бейдж состояния документа. Цвета — общие токены бейджей: жёлтый требует внимания,
/// голубой — в работе, зелёный — закончено.
class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status});

  final DocStatus status;

  @override
  Widget build(BuildContext context) {
    final (bg, fg, label) = switch (status) {
      DocStatus.isNew => (AppColors.kBadgeWarningBg, AppColors.kBadgeWarningText, t.portal.inventory.statusNew),
      DocStatus.downloaded => (AppColors.kBadgeInfoBg, AppColors.kBadgeInfoText, t.portal.inventory.statusDownloaded),
      DocStatus.done => (AppColors.kBadgeSuccessBg, AppColors.kBadgeSuccessText, t.portal.inventory.statusDone),
    };
    return Container(
      padding: AppInsets.badge,
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(AppSizes.kText12)),
      child: Text(
        label,
        style: TextStyle(fontSize: AppSizes.kText12, color: fg, fontWeight: FontWeight.w600),
      ),
    );
  }
}
