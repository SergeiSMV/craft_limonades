import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/sync/data_versions.dart';
import '../../../../core/widgets/data_versions_listener.dart';
import '../../../data/cells_repository.dart';
import '../../../data/web_download.dart';
import '../cells/cell_settings_card.dart';
import '../cells/cell_settings_sheet.dart';
import '../cells/cells_controller.dart';
import '../cells/cells_import_dialog.dart';
import '../cells/cells_list_card.dart';
import '../cells/cells_print_dialog.dart';
import '../cells/cells_toolbar.dart';
import '../cells/floor_cell_dialogs.dart';
import '../settings/access_common.dart';
import '../ui/portal_button.dart';

/// Страница «Ячейки» (ADHOC-57): полный список ячеек склада, справа — карточка ячейки с
/// галочками этикетки, загрузка и выгрузка `.xlsx` в формате rack_labels, печать трёх PDF.
///
/// Раскладка — по ширине страницы: от [AppSizes.kCellsSideMinPage] карточка стоит справа от
/// списка и прокручивается отдельно; уже — открывается окном по нажатию на строку.
/// Права: загрузка — [canImport], печать — [canLabels], галочки — [canEdit]; список и выгрузку
/// видит любой с правом раздела.
class CellsTab extends StatefulWidget {
  const CellsTab({
    super.key,
    required this.canImport,
    required this.canLabels,
    required this.canEdit,
    this.save = downloadBytes,
  });

  final bool canImport;
  final bool canLabels;
  final bool canEdit;

  /// Сохранение файла в браузере.
  final SaveFile save;

  @override
  State<CellsTab> createState() => _CellsTabState();
}

class _CellsTabState extends State<CellsTab> {
  late final _c = CellsController(getIt<CellsRepository>());
  final _search = TextEditingController();
  Timer? _debounce;
  bool _exporting = false;

  static const _debounceDelay = Duration(milliseconds: 250);

  @override
  void initState() {
    super.initState();
    _c.load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    _c.dispose();
    super.dispose();
  }

  /// Поиск по адресу — после паузы в наборе.
  void onSearch(String text) {
    _debounce?.cancel();
    _debounce = Timer(
      _debounceDelay,
      () => _c.setFilter(_c.filter.copyWith(query: text)),
    );
  }

  /// Уведомление внизу страницы.
  void notify(String text) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

  /// Загрузка файла; ячейки обновлены — перечитать страницу.
  Future<void> import() async {
    if (await showCellsImportDialog(context)) await _c.load();
  }

  /// Выгрузка всего склада в формате rack_labels.
  Future<void> export() async {
    setState(() => _exporting = true);
    final res = await getIt<CellsRepository>().exportCells();
    if (!mounted) return;
    setState(() => _exporting = false);
    res.fold(
      (f) => notify(t.portal.cells.exportFailed(message: failureText(f))),
      (bytes) => widget.save(
        bytes: bytes,
        filename: 'cells-${CellsRepository.warehouse}.xlsx',
        mime:
            'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      ),
    );
  }

  /// Новая напольная ячейка (ADHOC-61): адрес в окне, ответ сервера — уведомлением.
  Future<void> addFloorCell() async {
    final address = await showFloorCellAddressDialog(context);
    if (address == null || !mounted) return;
    final text = await _c.addFloorCell(address);
    if (mounted) notify(text);
  }

  /// Окно печати PDF.
  Future<void> printLabels() => showCellsPrintDialog(context, _c, widget.save);

  /// Карточка окном — на узкой странице.
  Future<void> openSheet() => showCellSettingsSheet(
    context,
    _c,
    canEdit: widget.canEdit,
    onSaved: notify,
  );

  @override
  Widget build(BuildContext context) => DataVersionsListener(
    // ADHOC-60: ячейки изменились на сервере — перечитать, если нет несохранённых галочек.
    domains: const {DataDomain.cells},
    onChanged: _c.reloadIfClean,
    child: _page(),
  );

  /// Страница: панель, список и карточка ячейки — по ширине.
  Widget _page() => ListenableBuilder(
    listenable: _c,
    builder: (context, _) => LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < AppSizes.kPortalCompactWidth;
        final side = constraints.maxWidth >= AppSizes.kCellsSideMinPage;
        final padding = narrow ? AppInsets.pageCompact : AppInsets.page;
        final list = _list(side);
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: AppSizes.kPortalListMaxWidth,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: padding.copyWith(bottom: AppInsets.bottom16.bottom),
                  child: _toolbar(side),
                ),
                Expanded(
                  child: side && _c.view != null
                      ? Padding(
                          padding: padding.copyWith(top: 0, bottom: 0),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(child: _scroll(list, padding)),
                              AppBoxes.kWidth16,
                              SizedBox(
                                width: AppSizes.kCellsSideWidth,
                                child: _scroll(
                                  CellSettingsCard(
                                    c: _c,
                                    canEdit: widget.canEdit,
                                    onSaved: notify,
                                  ),
                                  padding,
                                ),
                              ),
                            ],
                          ),
                        )
                      : SingleChildScrollView(
                          padding: padding.copyWith(top: 0),
                          child: list,
                        ),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );

  /// Колонка с прокруткой и нижним полем страницы.
  Widget _scroll(Widget child, EdgeInsets padding) => SingleChildScrollView(
    padding: EdgeInsets.only(bottom: padding.bottom),
    child: child,
  );

  Widget _toolbar(bool side) {
    final s = t.portal.cells;
    return CellsToolbar(
      c: _c,
      search: _search,
      onSearch: onSearch,
      trailing: [
        if (!side && _c.picked.isNotEmpty)
          PortalButton(
            label: s.editPicked(count: _c.picked.length),
            icon: Icons.tune,
            onPressed: openSheet,
          ),
        if (widget.canEdit)
          PortalButton(
            label: s.floor.add,
            icon: Icons.add,
            onPressed: _c.view == null ? null : addFloorCell,
          ),
        if (widget.canImport)
          PortalButton(
            label: s.import,
            icon: Icons.upload_file_outlined,
            onPressed: import,
          ),
        PortalButton(
          label: s.export,
          icon: Icons.download,
          busy: _exporting,
          onPressed: export,
        ),
        if (widget.canLabels)
          PortalButton(
            label: s.print,
            icon: Icons.print_outlined,
            kind: PortalButtonKind.primary,
            onPressed: _c.view == null ? null : printLabels,
          ),
      ],
    );
  }

  Widget _list(bool side) {
    if (_c.view == null) {
      return SettingsListCard(
        loading: _c.loadError == null,
        error: _c.loadError,
        rows: const [],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CellsListCard(
          c: _c,
          onOpen: (_) {
            if (!side) openSheet();
          },
        ),
        if (_c.loadError != null) ...[
          AppBoxes.kHeight8,
          AccessError(_c.loadError!),
        ],
      ],
    );
  }
}
