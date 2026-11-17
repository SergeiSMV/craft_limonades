import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:craft_wms/core/gen/assets.gen.dart';
import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/router/app_router.dart';
import '../../../../core/scanner/hardware_scan_listener.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';
import '../../../../core/widgets/bar_buttons.dart';
import '../../../../core/widgets/box_tile.dart';
import '../../../../core/widgets/cell_change_sheet.dart';
import '../../../cz/presentation/widgets/cz_intake_scan.dart';
import '../../../stock/domain/catalog_models.dart';
import '../bloc/stock_entry_cubit.dart';
import 'entry_scan_actions.dart';
import 'entry_scan_field.dart';
import 'line_tile.dart';

/// Работа с выбранной ячейкой: шапка + поле скана + короба и строки россыпью + действия.
///
/// Здесь товар вводят россыпью. В свой короб кладут на его странице (ADHOC-46, как на
/// приёмке): там видно только содержимое короба, и строка не уйдёт в «не тот» короб.
class CellEntryView extends StatefulWidget {
  const CellEntryView({super.key, required this.state});

  final StockEntryState state;

  @override
  State<CellEntryView> createState() => _CellEntryViewState();
}

class _CellEntryViewState extends State<CellEntryView>
    with HardwareScanListener, CzIntakeScan, EntryScanActions<CellEntryView> {
  /// В ячейке строки ложатся россыпью.
  @override
  String? get scanBoxId => null;

  /// Скан ярлыка короба ячейки открывает его страницу.
  @override
  void onBoxScanned(String boxId) => unawaited(_openBox(boxId));

  /// Открыть страницу короба. Cubit передаётся тот же: короб - часть этого прохода.
  /// Марки, отсканированные россыпью, - до входа в короб (ADHOC-70).
  Future<void> _openBox(String boxId) async {
    if (!await czSettle() || !mounted) return;
    await context.router.push(EntryBoxRoute(cubit: cubit, boxId: boxId));
    refocusScan();
  }

  /// Новый короб: заводим и сразу открываем - следующие сканы пойдут в него. Ярлык кладовщик
  /// печатает со страницы короба.
  Future<void> _newBox() => _openBox(cubit.newBox());

  /// Закрыть ячейку, когда марки, отсканированные последними, легли в неё (ADHOC-70).
  Future<void> _finishCell() async {
    if (await czSettle()) cubit.finishCell();
  }

  /// Сменить ячейку текущего буфера (ошиблись ячейкой, товары верны): лист выбора → `changeCell`
  /// (строки и короба сохраняются, при слиянии с пройденной - суммируются), затем возврат
  /// фокуса скан-полю.
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
    if (cell != null && mounted) cubit.changeCell(cell);
    refocusScan();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final cell = state.cell!;
    final boxes = state.boxes.reversed.toList(); // свежий короб - сверху
    final loose = state.looseLines.reversed.toList(); // свежая строка - сверху
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Шапка ячейки.
        Container(
          color: AppColors.kNeumorphicBg,
          padding: AppInsets.all8,
          child: Row(
            children: [
              // Вся шапка с адресом (иконка + текст + иконка «сменить») - одна кнопка смены ячейки.
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

              /// Новый свой короб в ячейке (ADHOC-46) - как «короб плюс» на приёмке.
              AppBoxes.kWidth8,
              BarIconButton(
                onPressed: _newBox,
                icon: MdiIcons.packageVariantPlus,
              ),

              /// Кнопка отмены последнего действия (удаление/редактирование строки)
              /// - только если есть что отменять.
              if (state.undoStack.isNotEmpty) ...[
                AppBoxes.kWidth8,
                NeumorphicButton(
                  onPressed: cubit.undo,
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
          child: EntryScanField(
            controller: scanController,
            focusNode: scanFocus,
            onTap: addManual,
            onSubmitted: onScan,
          ),
        ),
        Expanded(
          child: boxes.isEmpty && loose.isEmpty
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
              : ListView(
                  padding: AppInsets.h8 + AppInsets.top8,
                  children: [
                    // Короба сверху: их немного, и в них проваливаются; россыпь - ниже.
                    for (final b in boxes)
                      BoxTile(
                        title: t.stockEntry.boxTitle(code: b.code),
                        subtitle: t.stockEntry.cellPositions(
                          count: state.linesOf(b.id).length,
                        ),
                        onTap: () => _openBox(b.id),
                      ),
                    for (final line in loose)
                      LineTile(
                        line: line,
                        onLongPress: () => showLineMenu(line),
                      ),
                  ],
                ),
        ),

        /// Кнопка завершения работы с ячейкой (сохранение буфера на сервере и возврат к выбору ячейки).
        SafeArea(
          top: false,
          child: Padding(
            padding: AppInsets.all16,
            child: FilledButton.icon(
              onPressed: state.lines.isEmpty ? null : _finishCell,
              icon: const Icon(Icons.check),
              label: Text(t.stockEntry.finishCell),
            ),
          ),
        ),
      ],
    );
  }
}
