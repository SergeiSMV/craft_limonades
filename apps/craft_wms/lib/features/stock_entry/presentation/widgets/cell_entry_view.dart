import 'package:craft_wms/core/gen/assets.gen.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/error/failure.dart';
import '../../../../core/widgets/bind_prompt_dialog.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/scanner/hardware_scan_listener.dart';
import '../../../../core/scanner/scan_code.dart';
import '../../../../core/scanner/scan_deduper.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';
import '../../../../core/widgets/good_picker_sheet.dart';
import '../../../stock/data/catalog_models.dart';
import '../../../stock/data/catalog_repository.dart';
import '../bloc/stock_entry_cubit.dart';
import 'cell_change_sheet.dart';
import 'date_qty_dialog.dart';
import 'line_tile.dart';

/// Работа с выбранной ячейкой: шапка + поле скана товара + список строк буфера + действия.
class CellEntryView extends StatefulWidget {
  const CellEntryView({super.key, required this.state});

  final StockEntryState state;

  @override
  State<CellEntryView> createState() => _CellEntryViewState();
}

class _CellEntryViewState extends State<CellEntryView>
    with HardwareScanListener {
  final _scanController = TextEditingController();
  final _scanFocus = FocusNode();

  /// Отсекает дубль, если устройство отдаёт код и в поле, и интентом.
  final _deduper = ScanDeduper();

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

  /// Код с аппаратного сканера (intent-режим) — тот же путь, что у ввода в поле.
  @override
  void onHardwareScan(ScanCode code) =>
      _onScan(code.raw, symbology: code.symbology);

  /// Скан ШК товара. Порядок резолва: копилка привязок прохода → сервер → ручная привязка. Локальный
  /// шаг нужен, чтобы повторный скан любого уже привязанного за проход ШК узнавался сразу, а не бил в
  /// 404 (данные ещё не на сервере) — сколько бы ШК ни было на товар. По завершении — возврат фокуса.
  ///
  /// Если товар не нашёлся, а код опознан как адрес ячейки, ручной выбор товара НЕ открываем:
  /// иначе адрес ячейки привязался бы к выбранному товару как штрихкод — испорченный справочник
  /// вместо опечатки.
  ///
  /// Единая точка для обоих источников кода, поэтому отсечение дубля стоит здесь: если бы оно
  /// сидело только на ветке потока, пара «поле + интент» дала бы две строки остатка.
  Future<void> _onScan(String value, {String? symbology}) async {
    final code = value.trim();
    _scanController.clear();
    if (code.isNotEmpty && _deduper.allow(code)) {
      // Отдельной проверки «привязан за этот проход» больше нет (ADHOC-14): привязка уходит
      // обычной операцией очереди и сразу ложится в кэш с пометкой «ожидает», а резолв
      // кэш-first её оттуда и достаёт. Одна дорога вместо двух.
      {
        final resolved = await _cubit.resolveBarcode(code);
        if (!mounted) return;
        // Проверить не удалось. Прежде это давало тот же null, что «ШК не привязан», и экран
        // молча открывал выбор товара — то есть предлагал привязку, опираясь на факт, которого
        // у него не было. Теперь причина названа вслух, а решение остаётся за кладовщиком:
        // он стоит у стеллажа с упаковкой в руках, и его наблюдение не хуже нашего кэша.
        // Офлайн и отказ сервера разведены: «не найден по локальной базе» кладовщик может
        // доверить своей памяти, «не удалось проверить» — повод позвать админа.
        if (resolved.isLeft) {
          await _bindUnverified(code, resolved.left);
          return;
        }
        final good = resolved.right;
        if (good != null) {
          await _collectAndAdd(good, scannedCode: code); // есть в БД или в кэше
        } else if (classifyScan(code, symbology: symbology) == ScanKind.cell) {
          _snack(t.stockEntry.scannedCellInGood);
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

  /// Привязать ШК, который не удалось проверить на сервере.
  ///
  /// Отказ не делает работу невозможной: кладовщик может опознать товар сам. Но и выдавать
  /// непроверенный код за «свободный» нельзя — поэтому спрашиваем, назвав причину. Привязка
  /// ложится в копилку прохода и уедет с первым checkpoint на финале, где `bind` идемпотентен;
  /// если код окажется занят другим товаром, сервер ответит конфликтом и он попадёт на экран
  /// разбора. Строка остатка от этого не страдает: товар выбран руками, по упаковке.
  Future<void> _bindUnverified(String code, Failure failure) async {
    final reason = failure is NetworkFailure
        ? t.stockEntry.barcodeOffline(barcode: code)
        : t.stockEntry.barcodeLookupFailed(barcode: code);
    final confirmed = await showBindPromptDialog(
      context,
      title: t.stockEntry.bindOfflineTitle,
      body: reason,
      confirmLabel: t.stockEntry.bindOfflineConfirm,
      cancelLabel: t.stockEntry.bindOfflineCancel,
    );
    if (!confirmed || !mounted) return;
    final picked = await _pickGood();
    if (picked == null || !mounted) return;
    await _collectAndAdd(picked, scannedCode: code, newBarcode: code);
  }

  /// Ручное добавление товара (без ШК) — кнопки «неверный товар» тут нет (нет ШК).
  Future<void> _addManual() async {
    final picked = await _pickGood();
    if (picked != null && mounted) await _collectAndAdd(picked);
    _refocusScan();
  }

  /// Спросить дату + количество и добавить строку в буфер. [scannedCode] — ШК, которым опознан товар
  /// (включает кнопку «неверный товар»); [newBarcode] — если этот ШК ещё не привязан (уйдёт в копилку).
  Future<void> _collectAndAdd(
    Good good, {
    String? scannedCode,
    String? newBarcode,
  }) async {
    final res = await showDialog<DateQtyResult>(
      context: context,
      builder: (_) =>
          DateQtyDialog(good: good, allowWrongGood: scannedCode != null),
    );
    if (res == null || !mounted) return;
    if (res.wrongGood) {
      // allowWrongGood истинен только при непустом scannedCode
      await _handleWrongGood(scannedCode!, goodId: good.id);
      return;
    }
    await _cubit.addLine(
      good: good,
      date: res.date,
      qty: res.qty,
      newBarcode: newBarcode,
      symbology: newBarcode != null ? '' : null,
    );
  }

  /// «Неверный товар»: снять ошибочную привязку ШК и предложить правильный товар (перепривязка).
  ///
  /// Решение, что именно делать, принимает cubit: привязку, ещё не ушедшую на сервер, он снимает
  /// из очереди, ушедшую — отвязывает. Экрану различать эти случаи незачем, и обе ветки переживают
  /// отсутствие связи, потому что обе идут через очередь (ADHOC-14).
  Future<void> _handleWrongGood(String code, {required String goodId}) async {
    await _cubit.removeBarcode(code, goodId: goodId);
    if (!mounted) return;
    _snack(t.stockEntry.barcodeUnbound);
    final picked = await _pickGood();
    if (picked != null && mounted) {
      await _collectAndAdd(
        picked,
        scannedCode: code,
        newBarcode: code,
      ); // перепривязка на верный товар
    }
    _refocusScan();
  }

  /// Меню по долгому нажатию на строку: редактировать / удалить.
  Future<void> _showLineMenu(EntryLineDraft line) async {
    final action = await showModalBottomSheet<String>(
      backgroundColor: AppColors.kNeumorphicBg,
      context: context,
      builder: (_) => SafeArea(
        child: Padding(
          padding: AppInsets.all16,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              NeumorphicButton(
                onPressed: () => Navigator.of(context).pop('edit'),
                style: NeumorphicStyle(
                  shadowLightColor: AppColors.kNeumorphicLight,
                  shadowDarkColor: AppColors.kNeumorphicDark,
                  intensity: 1,
                  color: AppColors.kNeumorphicBg,
                  depth: 3,
                  shape: NeumorphicShape.flat,
                ),
                child: ListTile(
                  leading: const Icon(Icons.edit_outlined),
                  title: Text(t.stockEntry.edit),
                ),
              ),
              AppBoxes.kHeight8,
              NeumorphicButton(
                onPressed: () => Navigator.of(context).pop('delete'),
                style: NeumorphicStyle(
                  shadowLightColor: AppColors.kNeumorphicLight,
                  shadowDarkColor: AppColors.kNeumorphicDark,
                  intensity: 1,
                  color: AppColors.kNeumorphicBg,
                  depth: 3,
                  shape: NeumorphicShape.flat,
                ),
                child: ListTile(
                  leading: const Icon(
                    Icons.delete_outline,
                    color: AppColors.kDanger,
                  ),
                  title: Text(
                    t.stockEntry.delete,
                    style: const TextStyle(color: AppColors.kDanger),
                  ),
                ),
              ),
            ],
          ),
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
    backgroundColor: AppColors.kNeumorphicBg,
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    constraints: BoxConstraints(
      maxHeight: MediaQuery.of(context).size.height * 0.95,
    ),
    builder: (_) => GoodPickerSheet(repo: getIt<CatalogRepository>()),
  );

  /// Сменить ячейку текущего буфера (ошиблись ячейкой, товары верны): лист выбора → `changeCell`
  /// (строки сохраняются, при слиянии с пройденной — суммируются), затем возврат фокуса скан-полю.
  Future<void> _changeCell() async {
    final cell = await showModalBottomSheet<Cell>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.95,
      ),
      builder: (_) => const CellChangeSheet(),
    );
    if (cell != null && mounted) _cubit.changeCell(cell);
    _refocusScan();
  }

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
          color: AppColors.kNeumorphicBg,
          padding: AppInsets.all8,
          child: Row(
            children: [
              // Вся шапка с адресом (иконка + текст + иконка «сменить») — одна кнопка смены ячейки.
              Expanded(
                child: NeumorphicButton(
                  onPressed: _changeCell,
                  style: NeumorphicStyle(
                    shadowLightColor: AppColors.kNeumorphicLight,
                    shadowDarkColor: AppColors.kNeumorphicDark,
                    intensity: 1,
                    color: AppColors.kNeumorphicBg,
                    depth: 3,
                    shape: NeumorphicShape.flat,
                    boxShape: NeumorphicBoxShape.roundRect(
                      BorderRadius.circular(8),
                    ),
                  ),
                  child: InkWell(
                    onTap: _changeCell,
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            t.stockEntry.currentCell(address: cell.address),
                            style: SemiboldTextStyles().semiboldInter14
                                .copyWith(color: AppColors.kSidebarHover),
                          ),
                        ),
                        AppBoxes.kWidth8,
                        Icon(
                          MdiIcons.cogTransfer,
                          size: AppSizes.kIcon25,
                          color: AppColors.kSidebarHover,
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              /// Кнопка отмены последнего действия (удаление/редактирование строки)
              /// — только если есть что отменять.
              if (state.undoStack.isNotEmpty) ...[
                AppBoxes.kWidth8,
                NeumorphicButton(
                  onPressed: _cubit.undo,
                  style: NeumorphicStyle(
                    shadowLightColor: AppColors.kNeumorphicLight,
                    shadowDarkColor: AppColors.kNeumorphicDark,
                    intensity: 1,
                    color: AppColors.kNeumorphicBg,
                    depth: 3,
                    shape: NeumorphicShape.flat,
                    boxShape: NeumorphicBoxShape.roundRect(
                      AppBorders.kCircular8,
                    ),
                  ),
                  padding: AppInsets.all12,
                  child: Icon(
                    MdiIcons.undo,
                    color: AppColors.kSidebarHover,
                    size: AppSizes.kIcon20,
                  ),
                ),
              ],
            ],
          ),
        ),
        Padding(
          padding: AppInsets.h8,
          child: Row(
            children: [
              Expanded(
                child: Neumorphic(
                  style: NeumorphicStyle(
                    shadowLightColor: AppColors.kNeumorphicLight,
                    shadowDarkColor: AppColors.kNeumorphicDark,
                    intensity: 1,
                    color: AppColors.kNeumorphicBg,
                    depth: 3,
                    shape: NeumorphicShape.flat,
                    boxShape: NeumorphicBoxShape.roundRect(
                      AppBorders.kCircular8,
                    ),
                  ),
                  child: TextField(
                    onTap: _addManual,
                    showCursor: false,
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
                      fillColor: AppColors.kNeumorphicBg,
                      suffixIcon: Padding(
                        padding: AppInsets.right10,
                        child: Icon(
                          MdiIcons.viewList,
                          color: AppColors.kSidebarHover,
                          size: AppSizes.kIcon25,
                        ),
                      ),
                      hintText: t.stockEntry.scanGood,
                      hintStyle: RegularTextStyles().regularInter14.copyWith(
                        color: AppColors.kSidebarHover,
                      ),
                      border: const OutlineInputBorder(
                        borderRadius: AppBorders.kCircular8,
                        borderSide: BorderSide.none,
                      ),
                      isDense: true,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: state.lines.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Assets.icons.stockEntryEmpty.image(
                        width: 120,
                        height: 120,
                      ),
                      Text(
                        t.stockEntry.emptyBuffer,
                        style: RegularTextStyles().regularInter14.copyWith(
                          color: AppColors.kTextMuted,
                        ),
                      ),
                    ],
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

        /// Кнопка завершения работы с ячейкой (сохранение буфера на сервере и возврат к выбору ячейки).
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
