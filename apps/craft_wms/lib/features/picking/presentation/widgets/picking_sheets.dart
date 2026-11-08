import 'package:flutter/material.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';
import '../../../../core/utils/date_time_format.dart';
import '../../../../core/utils/qty_format.dart';
import '../../../../core/widgets/neumorphic_action_button.dart';
import '../../../../core/widgets/neumorphic_line_tile.dart';
import '../../../../core/widgets/section_title.dart';
import '../../domain/picking_models.dart';
import '../../domain/picking_sources.dart';
import '../../domain/picking_view.dart';
import 'picking_format.dart';

/// Нижние листы и подтверждения экрана заказа (P9-06).

/// Выбор, что взять из источника, когда вариантов несколько (строки, партии). `null` -
/// передумали.
Future<PickCandidate?> showCandidateSheet(
  BuildContext context,
  List<PickCandidate> candidates,
) => showModalBottomSheet<PickCandidate>(
  backgroundColor: AppColors.kNeumorphicBg,
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (ctx) => SafeArea(
    child: ListView(
      shrinkWrap: true,
      padding: AppInsets.h8,
      children: [
        SectionTitle(title: t.picking.chooseTitle),
        for (final c in candidates)
          Padding(
            padding: AppInsets.bottom8,
            child: NeumorphicLineTile(
              title: c.line.goodName,
              subtitle: [
                t.picking.batch(date: batchDate(c.productionDate)),
                t.picking.available(qty: fmtQty(c.available), uom: c.line.uom),
              ].join('\n'),
              onTap: () => Navigator.of(ctx).pop(c),
            ),
          ),
      ],
    ),
  ),
);

/// Что берут - над полем количества: товар, партия, откуда.
Widget candidateHeader(PickCandidate c) => Column(
  crossAxisAlignment: CrossAxisAlignment.start,
  children: [
    Text(
      c.line.goodName,
      style: SemiboldTextStyles().semiboldInter14.copyWith(
        color: AppColors.kTextMain,
      ),
    ),
    for (final s in [
      t.picking.batch(date: batchDate(c.productionDate)),
      t.picking.pickFromCell(cell: c.cellAddress),
      t.picking.available(qty: fmtQty(c.available), uom: c.line.uom),
    ])
      Text(
        s,
        style: RegularTextStyles().regularInter14.copyWith(
          color: AppColors.kTextMuted,
        ),
      ),
  ],
);

/// Строка заказа: подбор, свои пики (касание - вернуть), «не хватает». Вернуть пик можно
/// у заказа в работе у этого кладовщика ([canAct]) и без связи; «не хватает» - только со
/// связью ([canShortage]).
Future<void> showLineSheet(
  BuildContext context, {
  required PickingOrderView view,
  required PickingLine line,
  required bool canAct,
  required bool canShortage,
  required ValueChanged<PickingPick> onUnpick,
  required VoidCallback onShortage,
}) => showModalBottomSheet<void>(
  backgroundColor: AppColors.kNeumorphicBg,
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  constraints: BoxConstraints(
    maxHeight: MediaQuery.of(context).size.height * 0.9,
  ),
  builder: (ctx) {
    final picks = view.picksOf(line.id);
    final muted = RegularTextStyles().regularInter14.copyWith(
      color: AppColors.kTextMuted,
    );
    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        padding: AppInsets.h8,
        children: [
          Text(
            line.goodName,
            style: SemiboldTextStyles().semiboldInter16.copyWith(
              color: AppColors.kTextMain,
            ),
          ),
          AppBoxes.kHeight4,
          for (final s in lineLines(view, line)) Text(s, style: muted),
          if (picks.isNotEmpty) ...[
            SectionTitle(title: t.picking.sectionPicks),
            for (final vp in picks)
              Padding(
                padding: AppInsets.bottom8,
                child: NeumorphicLineTile(
                  title: t.picking.pickTitle,
                  subtitle: pickLines(view, vp, line.uom).join('\n'),
                  trailing: canAct && !vp.returnPending
                      ? t.picking.unpick
                      : null,
                  onTap: () {
                    if (!canAct || vp.returnPending) return;
                    Navigator.of(ctx).pop();
                    onUnpick(vp.pick);
                  },
                ),
              ),
          ],
          if (canShortage) ...[
            AppBoxes.kHeight8,
            NeumorphicActionButton(
              label: line.shortage
                  ? t.picking.shortageOff
                  : t.picking.shortageOn,
              icon: MdiIcons.alertOutline,
              onPressed: () {
                Navigator.of(ctx).pop();
                onShortage();
              },
            ),
          ],
          AppBoxes.kHeight16,
        ],
      ),
    );
  },
);

/// Подтверждение действия; `true` - да.
Future<bool> confirmPicking(
  BuildContext context, {
  required String title,
  required String body,
  required String yes,
  required String no,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      insetPadding: AppInsets.h8,
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(no),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(yes),
        ),
      ],
    ),
  );
  return ok ?? false;
}
