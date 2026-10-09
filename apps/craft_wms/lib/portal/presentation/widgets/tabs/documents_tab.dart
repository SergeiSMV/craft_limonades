import 'package:flutter/material.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/error/failure.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../data/documents_repository.dart';
import '../../../data/web_download.dart';

/// Вкладка документов оператора (P-FS-09, статусы — P3-02): рабочий список документов одной
/// формы. Оператор скачивает .xlsx, заносит в 1С и отмечает выполненным; необработанные идут
/// сверху. Данные тянутся при открытии; всё admin-only на бэке.
///
/// Одна вкладка на все формы (P4-10): «Инвентаризация» и «Приход» различаются только формой
/// документов и подписями, а работа оператора с документом одна и та же. Две копии вкладки
/// разошлись бы на первой же правке — например, в отметке «Выполнено».
class DocumentsTab extends StatefulWidget {
  const DocumentsTab({
    super.key,
    required this.kind,
    required this.title,
    required this.description,
    required this.mark,
    required this.empty,
  });

  /// Форма документов: `stock_entry` — ввод остатков, `receipt` — «Поступление».
  final String kind;

  final String title;
  final String description;

  /// Название документа в строке списка.
  final String mark;

  /// Текст пустого списка.
  final String empty;

  @override
  State<DocumentsTab> createState() => _DocumentsTabState();
}

class _DocumentsTabState extends State<DocumentsTab> {
  final _repo = getIt<DocumentsRepository>();

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
    final res = await _repo.listDocuments(kind: widget.kind);
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
      (f) => _snack(t.portal.documents.error(message: _errorText(f))),
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
        title: Text(t.portal.documents.confirmTitle),
        content: Text(t.portal.documents.confirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(t.portal.documents.confirmNo),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(t.portal.documents.confirmYes),
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
      (f) => _snack(t.portal.documents.error(message: _errorText(f))),
      (_) {
        _snack(t.portal.documents.doneOk);
        _load();
      },
    );
  }

  /// Показать историю документа: кто и когда его сформировал, скачал, отметил выполненным.
  Future<void> _showHistory(PortalDoc doc) async {
    final res = await _repo.events(doc.id);
    if (!mounted) return;
    res.fold(
      (f) => _snack(t.portal.documents.error(message: _errorText(f))),
      (events) => showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(t.portal.documents.historyTitle),
          content: SizedBox(
            width: AppSizes.kContentMaxWidth / 2,
            child: events.isEmpty
                ? Text(t.portal.documents.historyEmpty)
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [for (final e in events) _HistoryRow(event: e)],
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(t.portal.documents.close),
            ),
          ],
        ),
      ),
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
                    widget.title,
                    style: const TextStyle(fontSize: AppSizes.kText24, fontWeight: FontWeight.w600),
                  ),
                  AppBoxes.kHeight8,
                  Text(
                    widget.description,
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
            t.portal.documents.error(message: _errorText(_error!)),
            style: const TextStyle(color: AppColors.kDanger, fontSize: AppSizes.kText15),
          ),
          AppBoxes.kHeight16,
          OutlinedButton(onPressed: _load, child: Text(t.portal.documents.retry)),
        ],
      );
    }
    if (_docs.isEmpty) {
      return Padding(
        padding: AppInsets.all32,
        child: Center(
          child: Text(
            widget.empty,
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
            mark: widget.mark,
            downloading: _downloading.contains(d.id),
            marking: _marking.contains(d.id),
            onDownload: () => _download(d),
            onMarkDone: () => _markDone(d),
            onHistory: () => _showHistory(d),
          ),
      ],
    );
  }
}

/// Строка документа: склад · дата · число позиций · статус + скачивание и отметка «Выполнено».
class _DocRow extends StatelessWidget {
  const _DocRow({
    required this.doc,
    required this.mark,
    required this.downloading,
    required this.marking,
    required this.onDownload,
    required this.onMarkDone,
    required this.onHistory,
  });

  final PortalDoc doc;

  /// Название документа в строке.
  final String mark;
  final bool downloading;
  final bool marking;
  final VoidCallback onDownload;
  final VoidCallback onMarkDone;
  final VoidCallback onHistory;

  /// Формат даты документа: `дд.мм.гггг чч:мм` в локальной зоне.
  String _date(DateTime dt) {
    final l = dt.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(l.day)}.${two(l.month)}.${l.year} ${two(l.hour)}:${two(l.minute)}';
  }

  /// Заголовок строки: документ · склад, а у «Поступления» ещё поставщик и его документ —
  /// по ним оператор узнаёт приход среди других и находит накладную для 1С (P4-10, ADHOC-23).
  String _title() {
    if (doc.kind != 'receipt') return '$mark · ${doc.warehouseName}';
    final supplier = doc.supplier.isEmpty ? t.portal.receipt.noSupplier : doc.supplier;
    final supplierDoc = doc.docNumber.isEmpty
        ? ''
        : ' · ${t.portal.receipt.doc(number: doc.docNumber, date: doc.docDate.replaceAll('-', '.'))}';
    return '$mark · $supplier$supplierDoc · ${doc.warehouseName}';
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
            Flexible(child: Text(_title())),
            AppBoxes.kWidth8,
            _StatusBadge(status: doc.status),
          ],
        ),
        subtitle: Text(
          '${_date(doc.createdAt)} · ${t.portal.documents.lines(count: doc.linesCount)}',
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
                      tooltip: t.portal.documents.markDone,
                      onPressed: onMarkDone,
                    ),
            IconButton(
              icon: const Icon(Icons.history),
              tooltip: t.portal.documents.history,
              onPressed: onHistory,
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
                    tooltip: t.portal.documents.download,
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
      DocStatus.isNew => (AppColors.kBadgeWarningBg, AppColors.kBadgeWarningText, t.portal.documents.statusNew),
      DocStatus.downloaded => (AppColors.kBadgeInfoBg, AppColors.kBadgeInfoText, t.portal.documents.statusDownloaded),
      DocStatus.done => (AppColors.kBadgeSuccessBg, AppColors.kBadgeSuccessText, t.portal.documents.statusDone),
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

/// Строка истории: что произошло, когда и кто это сделал.
class _HistoryRow extends StatelessWidget {
  const _HistoryRow({required this.event});

  final DocEvent event;

  /// Человекочитаемое название события. Незнакомое показываем как есть — лучше сырой код,
  /// чем пустая строка: журнал читают, когда разбираются в расхождении.
  String get _label => switch (event.event) {
        'created' => t.portal.documents.eventCreated,
        'downloaded' => t.portal.documents.eventDownloaded,
        'done' => t.portal.documents.eventDone,
        'generation_failed' => t.portal.documents.eventGenerationFailed,
        _ => event.event,
      };

  /// Формат отметки времени: `дд.мм.гггг чч:мм` в локальной зоне.
  String _at(DateTime dt) {
    final l = dt.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(l.day)}.${two(l.month)}.${l.year} ${two(l.hour)}:${two(l.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final failed = event.event == 'generation_failed';
    return Padding(
      padding: AppInsets.bottom8,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${_at(event.createdAt)} · $_label',
            style: TextStyle(
              fontSize: AppSizes.kText14,
              color: failed ? AppColors.kDanger : AppColors.kTextMain,
            ),
          ),
          Text(
            // Автор мог не сохраниться: события до появления журнала и системные записи.
            event.userName.isEmpty ? t.portal.documents.eventSystem : event.userName,
            style: const TextStyle(fontSize: AppSizes.kText13, color: AppColors.kTextMuted),
          ),
          if (failed && event.details.isNotEmpty)
            Text(
              event.details,
              style: const TextStyle(fontSize: AppSizes.kText13, color: AppColors.kDanger),
            ),
        ],
      ),
    );
  }
}
