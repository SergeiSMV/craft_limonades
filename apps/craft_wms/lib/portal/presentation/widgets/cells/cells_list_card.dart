import 'package:flutter/material.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';
import '../../../domain/cells/cell_setup.dart';
import '../ui/portal_button.dart';
import '../ui/portal_card.dart';
import '../ui/portal_checkbox.dart';
import 'cell_row.dart';
import 'cells_controller.dart';

/// Список ячеек страницы «Ячейки» (ADHOC-57): галочка отметки, адрес, стеллаж, ярус, позиция,
/// балка и отметки этикетки. Нажатие на строку открывает её карточку ([onOpen]).
///
/// Раскладка - по ширине карточки: от [AppSizes.kCellsColumnsWidth] - колонками с шапкой, уже -
/// строками, где каждый реквизит своей подписанной строкой.
class CellsListCard extends StatelessWidget {
  const CellsListCard({super.key, required this.c, required this.onOpen});

  final CellsController c;

  /// Строку нажали - после того как она стала ячейкой в фокусе.
  final ValueChanged<CellSetup> onOpen;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final columns = constraints.maxWidth >= AppSizes.kCellsColumnsWidth;
      final rows = c.rows;
      final visible = c.visible;
      return PortalCard(
        children: [
          if (columns)
            _Header(c: c, rows: rows)
          else
            _PickAll(c: c, rows: rows),
          if (visible.isEmpty)
            Padding(
              padding: AppInsets.cardRow,
              child: Text(
                t.portal.cells.empty,
                style: RegularTextStyles().regularInter13.copyWith(
                  color: AppColors.kTextMuted,
                ),
              ),
            ),
          for (final cell in visible)
            CellRow(c: c, cell: cell, columns: columns, onOpen: onOpen),
          _Footer(c: c, shown: visible.length, total: rows.length),
        ],
      );
    },
  );
}

/// Галочка «все под фильтр»: стоит - отмечены все, черта - часть. Считает весь список под
/// фильтр, а не только показанные строки - «Показать ещё» на отметку не влияет.
PortalCheckbox _pickAllBox(CellsController c, List<CellSetup> rows) {
  final n = rows.where((x) => c.picked.contains(x.id)).length;
  return PortalCheckbox(
    value: n == 0 ? false : (n == rows.length ? true : null),
    onChanged: rows.isEmpty ? null : c.togglePickFiltered,
    semanticLabel: t.portal.cells.pickAll,
  );
}

class _Header extends StatelessWidget {
  const _Header({required this.c, required this.rows});

  final CellsController c;
  final List<CellSetup> rows;

  @override
  Widget build(BuildContext context) {
    final s = t.portal.cells;
    final style = SemiboldTextStyles().semiboldInter12.copyWith(
      color: AppColors.kTextMuted,
    );
    Text h(String v) => Text(v, style: style);
    return Padding(
      padding: AppInsets.tableHead,
      child: CellColumns(
        check: _pickAllBox(c, rows),
        address: h(s.colAddress),
        rack: h(s.colRack),
        tier: h(s.colTier),
        position: h(s.colPos),
        beam: h(s.colBeam),
        flags: h(s.colLabel),
      ),
    );
  }
}

/// Узкий список без шапки - галочка «все под фильтр» отдельной строкой.
class _PickAll extends StatelessWidget {
  const _PickAll({required this.c, required this.rows});

  final CellsController c;
  final List<CellSetup> rows;

  @override
  Widget build(BuildContext context) => Padding(
    padding: AppInsets.tableHead,
    child: Row(
      children: [
        _pickAllBox(c, rows),
        AppBoxes.kWidth12,
        Text(
          t.portal.cells.pickAll,
          style: SemiboldTextStyles().semiboldInter12.copyWith(
            color: AppColors.kTextMuted,
          ),
        ),
      ],
    ),
  );
}

/// Подвал: сколько показано, «Снять отметку», «Показать ещё».
class _Footer extends StatelessWidget {
  const _Footer({required this.c, required this.shown, required this.total});

  final CellsController c;
  final int shown;
  final int total;

  @override
  Widget build(BuildContext context) {
    final s = t.portal.cells;
    return Padding(
      padding: AppInsets.cardRow,
      child: Wrap(
        spacing: AppSizes.kChipSpacing,
        runSpacing: AppSizes.kChipSpacing,
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            s.shown(shown: shown, total: total),
            style: RegularTextStyles().regularInter13.copyWith(
              color: AppColors.kTextMuted,
            ),
          ),
          Wrap(
            spacing: AppSizes.kChipSpacing,
            children: [
              if (c.picked.isNotEmpty)
                PortalButton(
                  label: s.unpick(count: c.picked.length),
                  kind: PortalButtonKind.plain,
                  onPressed: c.unpickAll,
                ),
              if (shown < total)
                PortalButton(label: s.more, onPressed: c.showMore),
            ],
          ),
        ],
      ),
    );
  }
}
