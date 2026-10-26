import 'package:flutter/material.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/load_unit/box_code.dart';
import '../../../../core/widgets/neumorphic_line_tile.dart';
import '../../../../core/widgets/section_title.dart';
import '../../domain/stocktake_count.dart';
import '../../domain/stocktake_models.dart';
import 'stocktake_format.dart';

/// Позиции подсчёта ячейки (P10-04): короба, россыпь снимка и насчитанное сверх учёта.
///
/// Количеств «по учёту» нет — слепой счёт: кладовщик видит, что искать, и то, что насчитал сам.
/// Найденное отмечено галочкой справа.
class CountPositionsList extends StatelessWidget {
  const CountPositionsList({
    super.key,
    required this.count,
    required this.warehouseName,
    required this.onTapPosition,
    required this.onLongPressLine,
    required this.onLongPressBox,
  });

  final StocktakeCount count;

  /// Как склад показывается человеку; `null` — «Основной», не подписывается.
  final String? Function(String? id) warehouseName;

  /// Касание позиции россыпи — посчитать её без скана.
  final ValueChanged<StocktakePosition> onTapPosition;

  /// Долгое нажатие на насчитанное — исправить или убрать.
  final ValueChanged<CountLine> onLongPressLine;

  /// Касание найденного короба — снять отметку.
  final ValueChanged<CountBox> onLongPressBox;

  @override
  Widget build(BuildContext context) {
    final boxes = count.boxPositions;
    final loose = count.loosePositions;
    final extra = count.extraLines;
    final foreign = count.foreignBoxes;
    return ListView(
      padding: AppInsets.h8,
      children: [
        if (boxes.isNotEmpty || foreign.isNotEmpty) ...[
          SectionTitle(title: t.stocktake.sectionBoxes),
          for (final p in boxes) _boxTile(p),
          for (final b in foreign) _foreignBoxTile(b),
        ],
        if (loose.isNotEmpty) ...[
          SectionTitle(title: t.stocktake.sectionLoose),
          for (final p in loose) _looseTile(p),
        ],
        if (extra.isNotEmpty) ...[
          SectionTitle(title: t.stocktake.sectionExtra),
          for (final l in extra) _extraTile(l),
        ],
        AppBoxes.kHeight8,
      ],
    );
  }

  Widget _gap(Widget child) =>
      Padding(padding: AppInsets.bottom8, child: child);

  Widget _boxTile(StocktakePosition p) {
    final found = count.boxes
        .where((b) => b.loadUnitId == p.loadUnitId!.toLowerCase())
        .firstOrNull;
    final name = warehouseName(p.internalWarehouseId);
    // Ненайденный короб касанием не отмечается: найден — значит, отсканирован.
    return _gap(
      NeumorphicLineTile(
        title: t.stocktake.box(code: boxCode(p.loadUnitId!, czCode: p.czCode)),
        subtitle: name == null ? null : t.stocktake.warehouse(name: name),
        trailing: found == null ? null : t.stocktake.foundMark,
        onTap: () {
          if (found != null) onLongPressBox(found);
        },
      ),
    );
  }

  Widget _foreignBoxTile(CountBox b) => _gap(
    NeumorphicLineTile(
      title: t.stocktake.box(code: boxCode(b.loadUnitId, czCode: b.czCode)),
      subtitle: t.stocktake.boxForeign,
      trailing: t.stocktake.foundMark,
      onTap: () => onLongPressBox(b),
    ),
  );

  Widget _looseTile(StocktakePosition p) {
    final line = count.lineOf(p);
    final good = p.good!;
    return _gap(
      GestureDetector(
        onLongPress: line == null ? null : () => onLongPressLine(line),
        child: NeumorphicLineTile(
          title: good.name,
          subtitle: looseLines(
            productionDate: p.productionDate ?? '',
            warehouseName: warehouseName(p.internalWarehouseId),
            qty: line?.qty,
            uom: good.uom,
            marked: p.marked,
            marks: line?.marks.length ?? 0,
          ).join('\n'),
          trailing: (line?.qty ?? 0) > 0 ? t.stocktake.foundMark : null,
          onTap: () => onTapPosition(p),
        ),
      ),
    );
  }

  Widget _extraTile(CountLine l) => _gap(
    NeumorphicLineTile(
      title: l.good.name,
      subtitle: [
        ...looseLines(
          productionDate: l.productionDate,
          warehouseName: warehouseName(l.internalWarehouseId),
          qty: l.qty,
          uom: l.good.uom,
          marked: l.marks.isNotEmpty,
          marks: l.marks.length,
        ),
        t.stocktake.extra,
      ].join('\n'),
      onTap: () => onLongPressLine(l),
    ),
  );
}
