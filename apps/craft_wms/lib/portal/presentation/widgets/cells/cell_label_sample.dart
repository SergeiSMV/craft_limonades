import 'package:flutter/material.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';
import '../../../domain/cells/cell_setup.dart';
import '../../../domain/labels/beam_label.dart';
import 'cells_controller.dart';
import 'label_preview.dart';

/// Раздел «Как выглядит этикетка» карточки одной ячейки (ADHOC-57): образец с несохранёнными
/// галочками, размер этикетки и высота букв.
///
/// Как: кегль единый на все этикетки склада того же размера балки и того же «со штрих-кодом /
/// без» - как в PDF; поэтому набор для кегля - весь склад, где у этой ячейки уже стоят
/// несохранённые галочки.
class CellLabelSample extends StatelessWidget {
  const CellLabelSample({super.key, required this.c, required this.cell});

  final CellsController c;
  final CellSetup cell;

  @override
  Widget build(BuildContext context) {
    final s = t.portal.cells.side;
    final now = cell.copyWith(
      labelSmall: c.value(CellFlag.small) == true,
      isFloor: c.value(CellFlag.floor) == true,
      labelBarcode: c.value(CellFlag.barcode) == true,
    );
    final profile = now.labelSmall ? BeamProfile.small : BeamProfile.large;
    final set =
        [
          for (final x in c.view!.cells)
            if (x.id == cell.id) now else x,
        ].where(
          // Напольные (ADHOC-61) печатаются с QR - своя группа кегля, как в PDF.
          (x) =>
              !x.isFloorStorage &&
              x.labelSmall == now.labelSmall &&
              x.labelBarcode == now.labelBarcode,
        );
    final font = beamFont(
      profile,
      set.map((x) => (address: x.address, floor: x.isFloor)),
      barcode: now.labelBarcode,
    );
    final muted = RegularTextStyles().regularInter12.copyWith(
      color: AppColors.kTextMuted,
    );
    final height = mm(profile.height);
    return Padding(
      padding: AppInsets.cardRow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            s.preview,
            style: SemiboldTextStyles().semiboldInter13.copyWith(
              color: AppColors.kTextMain,
            ),
          ),
          AppBoxes.kHeight8,
          LabelPreview(
            address: now.address,
            profile: profile,
            font: font,
            floor: now.isFloor,
            barcode: now.labelBarcode,
          ),
          AppBoxes.kHeight8,
          Text(
            now.labelSmall
                ? s.sizeSmall(height: height)
                : s.sizeLarge(height: height),
            style: muted,
          ),
          AppBoxes.kHeight4,
          Text(
            s.cap(
              cap: mm(font.capHeight),
              beam: now.labelSmall ? s.beamSmallOf : s.beamLargeOf,
              barcode: now.labelBarcode ? s.withBarcode : s.withoutBarcode,
            ),
            style: muted,
          ),
          if (!font.fits) ...[
            AppBoxes.kHeight4,
            Text(
              s.tooLong,
              style: RegularTextStyles().regularInter12.copyWith(
                color: AppColors.kDanger,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Миллиметры одной десятой, с запятой и без «,0»: 69,3 · 12.
String mm(double v) {
  final s = v.toStringAsFixed(1).replaceAll('.', ',');
  return s.endsWith(',0') ? s.substring(0, s.length - 2) : s;
}
