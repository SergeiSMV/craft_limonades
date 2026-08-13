import 'package:flutter/material.dart';

import '../../../core/constants/app_boxes.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_insets.dart';
import '../../../core/constants/app_sizes.dart';
import '../../../core/di/injection.dart';
import '../../../core/error/failure.dart';
import '../../../core/gen/strings.g.dart';
import '../../data/inventory_repository.dart';
import '../../data/web_download.dart';

/// Вкладка «Инвентаризация» (P-FS-09): список документов «ввод остатков» (закрытые сессии) +
/// скачивание .xlsx для сверки с 1С. Данные тянутся при открытии; всё admin-only на бэке.
class InventoryTab extends StatefulWidget {
  const InventoryTab({super.key});

  @override
  State<InventoryTab> createState() => _InventoryTabState();
}

class _InventoryTabState extends State<InventoryTab> {
  final _repo = getIt<InventoryRepository>();

  bool _loading = true;
  Failure? _error;
  List<StockEntryDoc> _docs = const [];
  final _downloading = <String>{}; // id документов, которые сейчас качаются

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

  /// Скачать .xlsx документа и сохранить в браузере.
  Future<void> _download(StockEntryDoc doc) async {
    if (_downloading.contains(doc.id)) return;
    setState(() => _downloading.add(doc.id));
    final res = await _repo.downloadReport(doc.id);
    if (!mounted) return;
    setState(() => _downloading.remove(doc.id));
    res.fold(
      (f) => _snack(t.portal.inventory.error(message: _errorText(f))),
      (bytes) => downloadBytes(
        bytes: bytes,
        filename: 'vvod-ostatkov-${doc.warehouseCode}.xlsx',
        mime: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      ),
    );
  }

  String _errorText(Failure f) => switch (f) {
        ServerFailure(:final message, :final statusCode) => message ?? 'HTTP $statusCode',
        NetworkFailure() => t.portal.login.errorNetwork,
        _ => t.portal.login.errorUnknown,
      };

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
      children: [for (final d in _docs) _DocRow(doc: d, downloading: _downloading.contains(d.id), onDownload: () => _download(d))],
    );
  }
}

/// Строка документа: склад · дата · пометка · число позиций + кнопка скачивания.
class _DocRow extends StatelessWidget {
  const _DocRow({required this.doc, required this.downloading, required this.onDownload});

  final StockEntryDoc doc;
  final bool downloading;
  final VoidCallback onDownload;

  String _date(DateTime dt) {
    final l = dt.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(l.day)}.${two(l.month)}.${l.year} ${two(l.hour)}:${two(l.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: AppInsets.bottom8,
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.kBorder),
        borderRadius: BorderRadius.circular(AppSizes.kText12),
      ),
      child: ListTile(
        leading: const Icon(Icons.description_outlined),
        title: Text('${t.portal.inventory.mark} · ${doc.warehouseName}'),
        subtitle: Text(
          '${_date(doc.closedAt)} · ${t.portal.inventory.lines(count: doc.linesCount)}',
          style: const TextStyle(fontSize: AppSizes.kText13, color: AppColors.kTextMuted),
        ),
        trailing: downloading
            ? const SizedBox(
                width: AppSizes.kIcon24,
                height: AppSizes.kIcon24,
                child: CircularProgressIndicator(strokeWidth: AppSizes.kIcon2),
              )
            : IconButton(
                icon: const Icon(Icons.download),
                tooltip: t.portal.inventory.download,
                onPressed: onDownload,
              ),
      ),
    );
  }
}
