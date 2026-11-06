import 'package:flutter/material.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';
import '../../../domain/cells/cell_setup.dart';
import '../ui/portal_badge.dart';
import '../ui/portal_checkbox.dart';
import 'cells_controller.dart';

/// Раскладка колонок списка ячеек — общая у шапки и строк, чтобы они не разошлись.
class CellColumns extends StatelessWidget {
  const CellColumns({
    super.key,
    required this.check,
    required this.address,
    required this.rack,
    required this.tier,
    required this.position,
    required this.beam,
    required this.flags,
  });

  final Widget check, address, rack, tier, position, beam, flags;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      check,
      AppBoxes.kWidth16,
      Expanded(flex: 8, child: address),
      AppBoxes.kWidth16,
      SizedBox(width: AppSizes.kCellsColRack, child: rack),
      AppBoxes.kWidth16,
      SizedBox(width: AppSizes.kCellsColTier, child: tier),
      AppBoxes.kWidth16,
      SizedBox(width: AppSizes.kCellsColPos, child: position),
      AppBoxes.kWidth16,
      SizedBox(width: AppSizes.kCellsColBeam, child: beam),
      AppBoxes.kWidth16,
      Expanded(flex: 7, child: flags),
    ],
  );
}

/// Строка ячейки (ADHOC-57): колонками или стопкой подписанных строк; нажатие — в фокус и
/// открыть карточку, галочка — отметить для массовой правки и печати.
class CellRow extends StatelessWidget {
  const CellRow({
    super.key,
    required this.c,
    required this.cell,
    required this.columns,
    required this.onOpen,
  });

  final CellsController c;
  final CellSetup cell;
  final bool columns;
  final ValueChanged<CellSetup> onOpen;

  /// Нажали на строку — в фокус и открыть карточку.
  void open() {
    c.focus(cell.id);
    onOpen(cell);
  }

  @override
  Widget build(BuildContext context) {
    final s = t.portal.cells;
    final focused = c.picked.isEmpty && c.focusId == cell.id;
    final muted = RegularTextStyles().regularInter13.copyWith(
      color: AppColors.kTextSecondary,
    );
    final check = PortalCheckbox(
      value: c.picked.contains(cell.id),
      onChanged: () => c.togglePick(cell.id),
      semanticLabel: s.pick(address: cell.address),
    );
    final address = Text(
      cell.address,
      style: SemiboldTextStyles().semiboldInter13.copyWith(
        color: AppColors.kTextMain,
      ),
    );
    final beam = cell.labelSmall ? s.small : s.large;
    final flags = _Flags(cell: cell);
    final body = columns
        ? CellColumns(
            check: check,
            address: address,
            rack: Text(cell.rackCode ?? '', style: muted),
            tier: Text('${cell.tier ?? ''}', style: muted),
            position: Text('${cell.position ?? ''}', style: muted),
            beam: Text(beam, style: muted),
            flags: flags,
          )
        : Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              check,
              AppBoxes.kWidth12,
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    address,
                    AppBoxes.kHeight4,
                    Text(
                      s.rackLine(value: cell.rackCode ?? s.noRack),
                      style: muted,
                    ),
                    Text(s.beamLine(value: beam.toLowerCase()), style: muted),
                    AppBoxes.kHeight4,
                    flags,
                  ],
                ),
              ),
            ],
          );
    return Material(
      color: focused
          ? AppColors.kBg
          : (c.picked.contains(cell.id)
                ? AppColors.kPopoverBg
                : AppColors.kCardBg),
      child: InkWell(
        onTap: open,
        hoverColor: AppColors.kBg,
        child: Padding(padding: AppInsets.cardRow, child: body),
      ),
    );
  }
}

/// Отметки этикетки в строке: нижняя ячейка, штрих-код, строка на карточке стеллажа.
class _Flags extends StatelessWidget {
  const _Flags({required this.cell});

  final CellSetup cell;

  @override
  Widget build(BuildContext context) {
    final s = t.portal.cells;
    return Wrap(
      spacing: AppSizes.kChipSpacing / 2,
      runSpacing: AppSizes.kChipSpacing / 2,
      children: [
        if (cell.isFloorStorage) PortalBadge(s.badgeFloorStorage),
        if (cell.isFloor) PortalBadge(s.badgeFloor),
        if (cell.labelBarcode)
          PortalBadge(s.badgeBarcode, tone: PortalBadgeTone.info),
        if (cell.sideCard)
          PortalBadge(s.badgeCard, tone: PortalBadgeTone.success),
      ],
    );
  }
}
