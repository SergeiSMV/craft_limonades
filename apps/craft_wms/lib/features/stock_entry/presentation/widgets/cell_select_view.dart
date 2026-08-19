import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../stock/data/catalog_models.dart';
import '../../../stock/data/catalog_repository.dart';
import '../bloc/stock_entry_cubit.dart';
import 'cell_picker_sheet.dart';
import 'committed_cell_tile.dart';

/// Выбор ячейки: поле скана/ввода адреса + список пройденных ячеек (тап — редактировать) + кнопка
/// «Завершить ввод». Все данные локальны до финала (вариант A).
class CellSelectView extends StatefulWidget {
  const CellSelectView({super.key, required this.committed});

  final List<CommittedCell> committed;

  @override
  State<CellSelectView> createState() => _CellSelectViewState();
}

class _CellSelectViewState extends State<CellSelectView> {
  final _controller = TextEditingController();
  final _repo = getIt<CatalogRepository>();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  StockEntryCubit get _cubit => context.read<StockEntryCubit>();

  /// Резолв ячейки по введённому/сканированному адресу (точное совпадение).
  Future<void> _submitAddress(String value) async {
    final address = value.trim();
    if (address.isEmpty) return;
    final res = await _repo.listCells(query: address);
    if (!mounted) return;
    final cell = res.fold<Cell?>((_) => null, (page) {
      for (final c in page.items) {
        if (c.address.toLowerCase() == address.toLowerCase()) return c;
      }
      return null;
    });
    if (cell == null) {
      _snack(t.stockEntry.cellNotFound);
      return;
    }
    _controller.clear();
    _cubit.selectCell(cell);
  }

  /// Выбор ячейки из списка (поиск по адресу).
  Future<void> _pickFromList() async {
    final cell = await showModalBottomSheet<Cell>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => CellPickerSheet(repo: _repo),
    );
    if (cell != null && mounted) _cubit.selectCell(cell);
  }

  /// Меню по долгому нажатию на пройденную ячейку: редактировать / удалить.
  Future<void> _showCellMenu(CommittedCell entry) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: Text(t.stockEntry.edit),
              onTap: () => Navigator.of(context).pop('edit'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: AppColors.kDanger),
              title: Text(t.stockEntry.deleteCell, style: const TextStyle(color: AppColors.kDanger)),
              onTap: () => Navigator.of(context).pop('delete'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'edit') {
      _cubit.selectCell(entry.cell);
    } else if (action == 'delete') {
      _cubit.removeCommittedCell(entry.cell.id);
    }
  }

  /// Показать снекбар с текстом (напр. «Ячейка не найдена»).
  void _snack(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final committed = widget.committed;
    return Padding(
      padding: AppInsets.h8,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            t.stockEntry.cellPrompt,
            style: RegularTextStyles().regularInter14.copyWith(color: AppColors.kTextMuted),
          ),
          AppBoxes.kHeight4,
          TextField(
            controller: _controller,
            autofocus: true,
            textInputAction: TextInputAction.done,
            onSubmitted: _submitAddress,
            decoration: InputDecoration(
              prefixIcon: Icon(MdiIcons.qrcode, size: AppSizes.kIcon25, color: AppColors.kSidebarHover),
              suffixIcon: InkWell(
                onTap: _pickFromList,
                child: Icon(MdiIcons.formatListBulleted, size: AppSizes.kIcon25, color: AppColors.kSidebarHover),
              ),
              hintText: t.stockEntry.cellHint,
              border: const OutlineInputBorder(borderRadius: AppBorders.kCircular8),
              isDense: true,
            ),
          ),
          if (committed.isNotEmpty) ...[
            AppBoxes.kHeight16,
            Text(
              t.stockEntry.committedTitle(count: committed.length),
              style: RegularTextStyles().regularInter14.copyWith(color: AppColors.kTextMuted),
            ),
            AppBoxes.kHeight8,
          ],
          Expanded(
            child: ListView.builder(
              padding: EdgeInsets.zero,
              itemCount: committed.length,
              // Свежая пройденная ячейка — сверху.
              itemBuilder: (context, i) {
                final entry = committed[committed.length - 1 - i];
                return CommittedCellTile(
                  entry: entry,
                  onTap: () => _cubit.selectCell(entry.cell),
                  onLongPress: () => _showCellMenu(entry),
                );
              },
            ),
          ),
          if (committed.isNotEmpty)
            SafeArea(
              top: false,
              child: Padding(
                padding: AppInsets.v16,
                child: FilledButton(
                  onPressed: () => _cubit.finishSession(),
                  child: Text(t.stockEntry.finishSession),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
