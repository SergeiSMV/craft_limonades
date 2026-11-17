import 'package:flutter/material.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/semibold_text.dart';
import '../../../../core/widgets/neumorphic_line_tile.dart';
import '../../../contents/domain/contents_entities.dart';
import '../bloc/problem_state.dart';
import 'problem_format.dart';

/// Что пометить в отсканированном: в коробе - его целиком или товар из него; в ячейке -
/// её короб (откроется он) или товар россыпи. Строки разных складов - разные позиции.
class ProblemChoice extends StatelessWidget {
  const ProblemChoice({
    super.key,
    required this.source,
    required this.onWholeBox,
    required this.onBox,
    required this.onGoods,
  });

  final ProblemSource source;
  final VoidCallback onWholeBox;
  final ValueChanged<LoadUnitView> onBox;
  final ValueChanged<ContentLine> onGoods;

  @override
  Widget build(BuildContext context) {
    final (title, children) = switch (source) {
      SourceBox(:final box, :final cell) => (
        t.problems.inBox(box: boxLabel(box), cell: cell.address),
        [
          NeumorphicLineTile(
            title: t.problems.wholeBox,
            subtitle: t.problems.positions(count: box.lines.length),
            onTap: onWholeBox,
          ),
          for (final l in box.lines) _line(l),
        ],
      ),
      SourceCell(:final cell, :final view) => (
        t.problems.inCell(cell: cell.address),
        [
          for (final b in view.loadUnits)
            NeumorphicLineTile(
              title: boxLabel(b),
              subtitle: t.problems.positions(count: b.lines.length),
              onTap: () => onBox(b),
            ),
          for (final l in view.loose) _line(l),
        ],
      ),
    };
    return ListView(
      padding: AppInsets.h8,
      children: [
        Text(title, style: SemiboldTextStyles().semiboldInter16),
        for (final c in children) ...[AppBoxes.kHeight8, c],
      ],
    );
  }

  Widget _line(ContentLine l) => NeumorphicLineTile(
    title: l.goodName ?? l.goodCode ?? '',
    subtitle: batchLabel(l),
    trailing: qtyLabel(l.qty, l.uom),
    onTap: () => onGoods(l),
  );
}
