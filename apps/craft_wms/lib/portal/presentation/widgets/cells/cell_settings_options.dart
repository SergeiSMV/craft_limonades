import 'package:flutter/material.dart';

import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';
import '../../../domain/cells/cell_setup.dart';
import '../ui/portal_checkbox.dart';
import 'cells_controller.dart';

/// Галочки ячейки: малая балка, нижняя ячейка, штрих-код и строка на карточке стеллажа.
/// «На карточке» недоступна, если среди выбранных нет ни одной ячейки со стеллажом.
class BeamOptions extends StatelessWidget {
  const BeamOptions({super.key, required this.c, required this.canEdit});

  final CellsController c;
  final bool canEdit;

  @override
  Widget build(BuildContext context) {
    final s = t.portal.cells.side;
    final hasRack = c.targets.any((x) => x.rackId != null);
    return _Block(
      title: s.beamTitle,
      children: [
        _Option(
          c: c,
          flag: CellFlag.small,
          title: s.small,
          hint: s.smallHint,
          canEdit: canEdit,
        ),
        _Option(
          c: c,
          flag: CellFlag.floor,
          title: s.floor,
          hint: s.floorHint,
          canEdit: canEdit,
        ),
        _Option(
          c: c,
          flag: CellFlag.barcode,
          title: s.barcode,
          hint: s.barcodeHint,
          canEdit: canEdit,
        ),
        _Option(
          c: c,
          flag: CellFlag.sideCard,
          title: s.sideCard,
          hint: hasRack ? s.sideCardHint : s.sideCardNoRack,
          canEdit: canEdit,
          enabled: hasRack,
        ),
      ],
    );
  }
}

class _Block extends StatelessWidget {
  const _Block({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: AppInsets.cardRow,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          style: SemiboldTextStyles().semiboldInter13.copyWith(
            color: AppColors.kTextMain,
          ),
        ),
        AppBoxes.kHeight4,
        ...children,
      ],
    ),
  );
}

/// Галочка с подписью и пояснением; нажимается вся строка.
class _Option extends StatelessWidget {
  const _Option({
    required this.c,
    required this.flag,
    required this.title,
    required this.hint,
    required this.canEdit,
    this.enabled = true,
  });

  final CellsController c;
  final CellFlag flag;
  final String title;
  final String hint;
  final bool canEdit;

  /// Галочка применима к выбору; нет - серая и не нажимается.
  final bool enabled;

  /// Нажали на галочку или подпись.
  void toggle() => c.toggle(flag);

  @override
  Widget build(BuildContext context) {
    final onTap = canEdit && enabled && !c.saving ? toggle : null;
    return InkWell(
      onTap: onTap,
      borderRadius: AppBorders.kCircular6,
      child: Padding(
        padding: AppInsets.v8,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            PortalCheckbox(
              value: c.value(flag),
              onChanged: onTap,
              semanticLabel: title,
            ),
            AppBoxes.kWidth12,
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: RegularTextStyles().regularInter13.copyWith(
                      color: enabled
                          ? AppColors.kTextMain
                          : AppColors.kTextMuted,
                    ),
                  ),
                  Text(
                    hint,
                    style: RegularTextStyles().regularInter12.copyWith(
                      color: AppColors.kTextMuted,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
