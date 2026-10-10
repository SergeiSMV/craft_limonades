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
import '../documents/doc_history_dialog.dart';
import '../documents/doc_row.dart';
import '../documents/mark_done_dialog.dart';

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
    required this.mark,
    required this.empty,
  });

  /// Форма документов: `stock_entry` — ввод остатков, `receipt` — «Поступление»,
  /// `movement` — «Движение».
  final String kind;

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
      (file) {
        downloadBytes(
          bytes: file.bytes,
          filename: file.filename,
          mime: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        );
        _load();
      },
    );
  }

  /// Отметить документ занесённым в 1С — с подтверждением: вернуть документ в работу нельзя.
  Future<void> _markDone(PortalDoc doc) async {
    if (_marking.contains(doc.id)) return;
    final confirmed = await showMarkDoneDialog(context);
    if (!confirmed || !mounted) return;

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
      (events) => showDocHistoryDialog(context, events),
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
    // Без карточки: список лежит прямо на фоне рабочей области, колонка прижата влево
    // (ADHOC-25) — неоморфные кнопки строк выдавлены из этого фона. Заголовок раздела
    // и пояснение — в шапке портала.
    // На узкой области (телефон) поля по краям меньше — иначе на текст не хватает ширины.
    final compact = MediaQuery.sizeOf(context).width < AppSizes.kPortalCompactContentWidth;
    return SingleChildScrollView(
      padding: compact ? AppInsets.all16 : AppInsets.all32,
      child: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: AppSizes.kContentMaxWidth),
          child: _body(),
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
    // Строки — во всю ширину колонки: иначе узкая строка (кнопки под текстом) брала бы
    // ширину своего текста и вставала по центру — у каждой строки со своим сдвигом.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final d in _docs)
          DocRow(
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
