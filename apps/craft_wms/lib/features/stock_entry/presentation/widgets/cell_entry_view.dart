import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';
import '../../../stock/data/catalog_models.dart';
import '../../../stock/data/catalog_repository.dart';
import '../bloc/stock_entry_cubit.dart';
import 'date_qty_dialog.dart';
import 'failure_text.dart';
import 'good_picker_sheet.dart';
import 'line_tile.dart';

/// Работа с выбранной ячейкой: шапка + поле скана товара + список строк буфера + действия.
class CellEntryView extends StatefulWidget {
  const CellEntryView({super.key, required this.state});

  final StockEntryState state;

  @override
  State<CellEntryView> createState() => _CellEntryViewState();
}

class _CellEntryViewState extends State<CellEntryView> {
  final _scanController = TextEditingController();
  final _scanFocus = FocusNode();
  final _repo = getIt<CatalogRepository>();

  @override
  void dispose() {
    _scanController.dispose();
    _scanFocus.dispose();
    super.dispose();
  }

  StockEntryCubit get _cubit => context.read<StockEntryCubit>();

  /// Вернуть фокус скан-полю (после диалогов) — иначе сканер DT50 печатает «в никуда».
  void _refocusScan() {
    if (mounted) _scanFocus.requestFocus();
  }

  /// Скан ШК товара. Порядок резолва: копилка привязок прохода → сервер → ручная привязка. Локальный
  /// шаг нужен, чтобы повторный скан любого уже привязанного за проход ШК узнавался сразу, а не бил в
  /// 404 (данные ещё не на сервере) — сколько бы ШК ни было на товар. По завершении — возврат фокуса.
  Future<void> _onScan(String value) async {
    final code = value.trim();
    _scanController.clear();
    if (code.isNotEmpty) {
      final local = _cubit.localGoodForBarcode(code);
      if (local != null) {
        await _collectAndAdd(local, scannedCode: code); // привязан за проход — просто строка
      } else {
        final good = await _cubit.resolveBarcode(code);
        if (!mounted) return;
        if (good != null) {
          await _collectAndAdd(good, scannedCode: code); // есть в БД
        } else {
          _snack(t.stockEntry.goodNotBound);
          final picked = await _pickGood();
          if (picked != null && mounted) {
            // новый ШК → в копилку прохода; scannedCode тот же для кнопки «неверный товар»
            await _collectAndAdd(picked, scannedCode: code, newBarcode: code);
          }
        }
      }
    }
    _refocusScan();
  }

  /// Ручное добавление товара (без ШК) — кнопки «неверный товар» тут нет (нет ШК).
  Future<void> _addManual() async {
    final picked = await _pickGood();
    if (picked != null && mounted) await _collectAndAdd(picked);
    _refocusScan();
  }

  /// Спросить дату + количество и добавить строку в буфер. [scannedCode] — ШК, которым опознан товар
  /// (включает кнопку «неверный товар»); [newBarcode] — если этот ШК ещё не привязан (уйдёт в копилку).
  Future<void> _collectAndAdd(Good good, {String? scannedCode, String? newBarcode}) async {
    final res = await showDialog<DateQtyResult>(
      context: context,
      builder: (_) => DateQtyDialog(good: good, allowWrongGood: scannedCode != null),
    );
    if (res == null || !mounted) return;
    if (res.wrongGood) {
      await _handleWrongGood(scannedCode!); // allowWrongGood истинен только при непустом scannedCode
      return;
    }
    _cubit.addLine(
      good: good,
      date: res.date,
      qty: res.qty,
      newBarcode: newBarcode,
      symbology: newBarcode != null ? '' : null,
    );
  }

  /// «Неверный товар»: снять ошибочную привязку ШК и предложить правильный товар (перепривязка).
  /// Привязка этой сессии — убираем из копилки локально; уже в БД — немедленный DELETE (коррекция
  /// не должна зависеть от финала: бросят проход — исправление всё равно сохранено).
  Future<void> _handleWrongGood(String code) async {
    if (_cubit.localGoodForBarcode(code) != null) {
      _cubit.removeLocalBarcode(code);
    } else {
      final res = await _repo.unbindBarcode(code);
      if (!mounted) return;
      final failed = res.fold((f) {
        _snack(stockEntryFailureText(f));
        return true;
      }, (_) => false);
      if (failed) {
        _refocusScan();
        return;
      }
    }
    _snack(t.stockEntry.barcodeUnbound);
    final picked = await _pickGood();
    if (picked != null && mounted) {
      await _collectAndAdd(picked, scannedCode: code, newBarcode: code); // перепривязка на верный товар
    }
    _refocusScan();
  }

  /// Меню по долгому нажатию на строку: редактировать / удалить.
  Future<void> _showLineMenu(EntryLineDraft line) async {
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
              leading: const Icon(
                Icons.delete_outline,
                color: AppColors.kDanger,
              ),
              title: Text(
                t.stockEntry.delete,
                style: const TextStyle(color: AppColors.kDanger),
              ),
              onTap: () => Navigator.of(context).pop('delete'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'delete') {
      _cubit.removeLine(line);
    } else if (action == 'edit') {
      await _editLine(line);
    }
  }

  /// Редактирование строки: диалог с текущими датой и количеством (без кнопки «неверный товар» —
  /// правка уже добавленной строки не про привязку ШК).
  Future<void> _editLine(EntryLineDraft line) async {
    final res = await showDialog<DateQtyResult>(
      context: context,
      builder: (_) => DateQtyDialog(
        good: line.good,
        initialDate: line.productionDate,
        initialQty: line.qty,
      ),
    );
    if (res == null || res.wrongGood || !mounted) return;
    _cubit.editLine(line, date: res.date, qty: res.qty);
  }

  /// Открыть нижний лист выбора товара из номенклатуры; возвращает выбранный товар или null.
  Future<Good?> _pickGood() => showModalBottomSheet<Good>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => GoodPickerSheet(repo: _repo),
  );

  /// Показать снекбар с текстом (сообщения потока ввода: «ШК не найден», «ШК отвязан» и т.п.).
  void _snack(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final cell = state.cell!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Шапка ячейки.
        Container(
          color: AppColors.kStockItemBg,
          padding: AppInsets.v8 + AppInsets.h14,
          child: Row(
            children: [
              const Icon(
                Icons.inventory_2_outlined,
                size: AppSizes.kIcon20,
                color: AppColors.kSidebarHover,
              ),
              AppBoxes.kWidth8,
              Expanded(
                child: Text(
                  t.stockEntry.currentCell(address: cell.address),
                  style: SemiboldTextStyles().semiboldInter14.copyWith(
                    color: AppColors.kSidebarHover,
                  ),
                ),
              ),
              if (state.undoStack.isNotEmpty)
                TextButton.icon(
                  onPressed: _cubit.undo,
                  icon: const Icon(Icons.undo, size: AppSizes.kIcon18),
                  label: Text(t.stockEntry.undo),
                ),
            ],
          ),
        ),
        TextField(
          cursorColor: AppColors.kPrimary,
          cursorWidth: 1,
          cursorHeight: 14,
          controller: _scanController,
          focusNode: _scanFocus,
          autofocus: true,
          // Ввод только сканером (аппаратная «клавиатура» DT50) — софт-клавиатуру не показываем,
          // чтобы после «Добавить»/скана она не всплывала. Ручной выбор товара — кнопкой ниже.
          keyboardType: TextInputType.none,
          textInputAction: TextInputAction.done,
          onSubmitted: _onScan,
          decoration: InputDecoration(
            filled: true,
            fillColor: AppColors.kPrimary,
            focusedBorder: const OutlineInputBorder(
              borderSide: BorderSide(color: AppColors.kPrimary),
            ),
            prefixIcon: const Icon(
              Icons.qr_code_scanner,
              size: AppSizes.kIcon20,
              color: AppColors.kBadgeSuccessBg,
            ),
            hintText: t.stockEntry.scanGood,
            hintStyle: RegularTextStyles().regularInter14.copyWith(
              color: AppColors.kBadgeSuccessBg,
            ),
            suffixIcon: InkWell(
              onTap: _addManual,
              child: Icon(
                MdiIcons.formatListBulleted,
                size: AppSizes.kIcon25,
                color: AppColors.kSidebarHover,
              ),
            ),
            isDense: true,
          ),
        ),
        Expanded(
          child: state.lines.isEmpty
              ? Center(
                  child: Text(
                    t.stockEntry.emptyBuffer,
                    style: RegularTextStyles().regularInter14.copyWith(
                      color: AppColors.kTextMuted,
                    ),
                  ),
                )
              : ListView.builder(
                  padding: AppInsets.h8 + AppInsets.top8,
                  itemCount: state.lines.length,
                  // От последнего добавленного: свежая строка — сверху.
                  itemBuilder: (context, i) {
                    final line = state.lines[state.lines.length - 1 - i];
                    return LineTile(
                      line: line,
                      onLongPress: () => _showLineMenu(line),
                    );
                  },
                ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: AppInsets.all16,
            child: FilledButton.icon(
              onPressed: state.lines.isEmpty ? null : _cubit.finishCell,
              icon: const Icon(Icons.check),
              label: Text(t.stockEntry.finishCell),
            ),
          ),
        ),
      ],
    );
  }
}
