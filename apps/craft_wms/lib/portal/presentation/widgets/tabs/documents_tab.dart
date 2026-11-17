import 'package:flutter/material.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/error/failure.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../domain/documents/documents_repository.dart';
import '../../../../core/web_files/web_download.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/sync/data_versions.dart';
import '../../../../core/widgets/data_versions_listener.dart';
import '../documents/doc_filter.dart';
import '../documents/doc_form.dart';
import '../documents/doc_history_dialog.dart';
import '../documents/doc_table.dart';
import '../documents/doc_toolbar.dart';
import '../documents/mark_done_dialog.dart';
import '../settings/access_common.dart';
import '../ui/portal_button.dart';
import '../ui/portal_card.dart';
import '../ui/portal_list_page.dart';

/// Вкладка документов оператора (P-FS-09, статусы - P3-02, таблица - ADHOC-26): рабочий список
/// документов одной формы. Оператор ищет документ, скачивает .xlsx, заносит в 1С и проводит;
/// ожидающие идут сверху. Данные тянутся при открытии; поиск и фильтр - по загруженному списку,
/// без запроса к серверу. Всё admin-only на бэке.
///
/// Одна вкладка на все формы (P4-10): «Инвентаризация» и «Приход» различаются только формой
/// документов и подписями, а работа оператора с документом одна и та же. Две копии вкладки
/// разошлись бы на первой же правке - например, в отметке «Выполнено».
class DocumentsTab extends StatefulWidget {
  const DocumentsTab({
    super.key,
    required this.kind,
    required this.empty,
    this.rights = (view: true, download: true, post: true),
    this.header,
  });

  /// Форма документов: `stock_entry` - ввод остатков, `receipt` - «Поступление»,
  /// `movement` - «Движение».
  final String kind;

  /// Текст пустого списка.
  final String empty;

  /// Действия с документами по правам должности (ADHOC-50): нет права - нет кнопки.
  final DocRights rights;

  /// Над панелью поиска, закреплён вместе с ней: переключатель видов «Инвентаризации».
  final Widget? header;

  @override
  State<DocumentsTab> createState() => _DocumentsTabState();
}

/// Права на действия с документами вида: смотреть историю, скачивать, проводить.
typedef DocRights = ({bool view, bool download, bool post});

class _DocumentsTabState extends State<DocumentsTab> {
  final _repo = getIt<DocumentsRepository>();

  bool _loading = true;
  Failure? _error;
  List<PortalDoc> _docs = const [];
  final _downloading = <String>{}; // id документов, которые сейчас качаются
  final _marking = <String>{}; // id документов, по которым идёт проведение

  /// Что показывать в колонках и по чему искать - по форме документов вкладки.
  late final _form = DocForm.of(widget.kind);
  DocFilter _filter = DocFilter.all;
  String _query = '';

  /// Сменить фильтр по состоянию в 1С.
  void _onFilter(DocFilter f) => setState(() => _filter = f);

  /// Запрос поиска изменился.
  void _onQuery(String q) => setState(() => _query = q);

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Загрузить список документов. [quiet] - перечитывание по версиям данных (ADHOC-60):
  /// таблица остаётся на экране до ответа, а ошибка не подменяет её - список просто прежний.
  Future<void> _load({bool quiet = false}) async {
    if (!quiet) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    final res = await _repo.listDocuments(kind: widget.kind);
    if (!mounted || (quiet && res.isLeft)) return;
    setState(() {
      _loading = false;
      res.fold((f) => _error = f, (docs) {
        _docs = docs;
        _error = null;
      });
    });
  }

  /// Документы изменились на сервере (ADHOC-60): тихо перечитать; поиск и фильтр не трогаются.
  void _onDataChanged() => _load(quiet: true);

  /// Скачать .xlsx документа и сохранить в браузере. Сервер отмечает документ скачанным,
  /// поэтому после успеха список перечитывается - иначе статус на экране отстанет от факта.
  Future<void> _download(PortalDoc doc) async {
    if (_downloading.contains(doc.id)) return;
    setState(() => _downloading.add(doc.id));
    final res = await _repo.downloadReport(doc.id);
    if (!mounted) return;
    setState(() => _downloading.remove(doc.id));
    res.fold((f) => _snack(t.portal.documents.error(message: _errorText(f))), (
      file,
    ) {
      downloadBytes(
        bytes: file.bytes,
        filename: file.filename,
        mime:
            'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      );
      _load();
    });
  }

  /// Провести документ - отметить занесённым в 1С, с подтверждением: вернуть его в работу нельзя.
  Future<void> _markDone(PortalDoc doc) async {
    if (_marking.contains(doc.id)) return;
    final confirmed = await showMarkDoneDialog(context);
    if (!confirmed || !mounted) return;

    setState(() => _marking.add(doc.id));
    final res = await _repo.markDone(doc.id);
    if (!mounted) return;
    setState(() => _marking.remove(doc.id));
    res.fold((f) => _snack(t.portal.documents.error(message: _errorText(f))), (
      _,
    ) {
      _snack(t.portal.documents.doneOk);
      _load();
    });
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
    ServerFailure(:final message, :final statusCode) =>
      message ?? 'HTTP $statusCode',
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
    // Панель поиска и фильтров закреплена сверху, прокручивается только таблица под ней
    // (ADHOC-26): поиск и фильтр нужны и в конце длинного списка. Ширина и поля - как у
    // остальных страниц-списков (ADHOC-56); заголовок раздела и пояснение - в шапке портала.
    return DataVersionsListener(
      domains: const {DataDomain.documents},
      onChanged: _onDataChanged,
      child: PortalListPage(
        header: widget.header,
        toolbar: DocToolbar(
          hint: _form.searchHint,
          onQuery: _onQuery,
          filter: _filter,
          counts: countByFilter(_docs),
          onFilter: _onFilter,
        ),
        body: _body(),
      ),
    );
  }

  /// Список под панелью: таблица или вместо неё загрузка / ошибка / пусто.
  Widget _body() {
    if (_loading) {
      return const SettingsListCard(loading: true, rows: []);
    }
    final error = _error;
    if (error != null) {
      return PortalCard(
        children: [
          Padding(
            padding: AppInsets.cardRow,
            child: Row(
              children: [
                Expanded(
                  child: AccessError(
                    t.portal.documents.error(message: _errorText(error)),
                  ),
                ),
                AppBoxes.kWidth8,
                PortalButton(label: t.portal.documents.retry, onPressed: _load),
              ],
            ),
          ),
        ],
      );
    }
    if (_docs.isEmpty) {
      return PortalCard(
        children: [
          Padding(
            padding: AppInsets.cardRow,
            child: Text(
              widget.empty,
              style: RegularTextStyles().regularInter13.copyWith(
                color: AppColors.kTextMuted,
              ),
            ),
          ),
        ],
      );
    }
    return DocTable(
      form: _form,
      docs: applyFilter(
        _docs,
        filter: _filter,
        query: _query,
        searchText: _form.searchText,
      ),
      downloading: _downloading,
      posting: _marking,
      onDownload: widget.rights.download ? _download : null,
      onPost: widget.rights.post ? _markDone : null,
      onHistory: widget.rights.view ? _showHistory : null,
    );
  }
}
