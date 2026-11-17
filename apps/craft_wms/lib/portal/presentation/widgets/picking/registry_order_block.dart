import 'package:flutter/material.dart';

import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';
import '../../../../core/utils/date_time_format.dart';
import '../../../../core/utils/doc_number.dart';
import '../../../../core/utils/qty_format.dart';
import '../../../data/picking_repository.dart';
import '../ui/portal_badge.dart';
import 'picking_labels.dart';

/// Заказ в предпросмотре реестра (P8-02): накладная, заказ и клиент - каждый своей строкой,
/// отметки (вид правки, нераспознанное, нехватка, отгружен, дособор), правки против прошлой
/// загрузки. Строки плана раскрываются нажатием на шапку: в реестре на день сотни строк.
class RegistryOrderBlock extends StatefulWidget {
  const RegistryOrderBlock({super.key, required this.order});

  final RegistryOrder order;

  @override
  State<RegistryOrderBlock> createState() => _RegistryOrderBlockState();
}

class _RegistryOrderBlockState extends State<RegistryOrderBlock> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final o = widget.order;
    final p = t.portal.picking;
    final muted = RegularTextStyles().regularInter13.copyWith(
      color: AppColors.kTextMuted,
    );
    final (kindLabel, kindTone) = switch (o.kind) {
      RegistryOrderKind.added => (p.kindNew, PortalBadgeTone.success),
      RegistryOrderKind.changed => (p.kindChanged, PortalBadgeTone.info),
      RegistryOrderKind.deleted => (p.kindDeleted, PortalBadgeTone.critical),
      RegistryOrderKind.restored => (p.kindRestored, PortalBadgeTone.info),
      RegistryOrderKind.unchanged => (p.kindUnchanged, PortalBadgeTone.neutral),
    };
    final number = o.number;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.kBorder),
        borderRadius: AppBorders.kCircular8,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: AppBorders.kCircular8,
            onTap: o.lines.isEmpty
                ? null
                : () => setState(() => _open = !_open),
            child: Padding(
              padding: AppInsets.all12,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          p.order(number: o.orderNumber),
                          style: SemiboldTextStyles().semiboldInter13.copyWith(
                            color: AppColors.kTextMain,
                          ),
                        ),
                        if (number != null)
                          Text(
                            p.number(
                              number: docNumber(DocKind.picking, number),
                            ),
                            style: muted,
                          ),
                        if (o.invoiceNumber.isNotEmpty)
                          Text(
                            p.invoice(number: o.invoiceNumber),
                            style: muted,
                          ),
                        if (o.client.isNotEmpty)
                          Text(p.client(name: o.client), style: muted),
                        AppBoxes.kHeight8,
                        Wrap(
                          spacing: AppSizes.kChipSpacing,
                          runSpacing: AppSizes.kChipSpacing,
                          children: [
                            PortalBadge(kindLabel, tone: kindTone),
                            if (o.hasUnknown)
                              PortalBadge(
                                p.badgeUnknown,
                                tone: PortalBadgeTone.warning,
                              ),
                            if (o.hasShortage)
                              PortalBadge(
                                p.badgeShortage,
                                tone: PortalBadgeTone.warning,
                              ),
                            if (o.shipped)
                              PortalBadge(
                                p.badgeShipped,
                                tone: PortalBadgeTone.critical,
                              ),
                            if (o.reopen)
                              PortalBadge(
                                p.badgeReopen,
                                tone: PortalBadgeTone.info,
                              ),
                          ],
                        ),
                        if (o.changes.isNotEmpty) ...[
                          AppBoxes.kHeight8,
                          for (final c in o.changes)
                            Text(_change(c), style: muted),
                        ],
                      ],
                    ),
                  ),
                  if (o.lines.isNotEmpty)
                    Icon(
                      _open ? Icons.expand_less : Icons.expand_more,
                      size: AppSizes.kIcon20,
                      color: AppColors.kTextMuted,
                    ),
                ],
              ),
            ),
          ),
          if (_open)
            for (final l in o.lines) ...[
              const Divider(height: 1, color: AppColors.kDivider),
              _LineRow(line: l),
            ],
        ],
      ),
    );
  }

  /// Правка одной строкой: что и с каким количеством.
  String _change(RegistryChange c) => pickingChangeText(
    kind: c.kind,
    goodCode: c.goodCode,
    goodName: c.goodName,
    oldQty: c.oldQty,
    newQty: c.newQty,
  );
}

/// Строка плана: товар, количество, партия, ячейка, остаток - каждый факт своей строкой;
/// нераспознанное, ячейка вне WMS и нехватка подсвечены.
class _LineRow extends StatelessWidget {
  const _LineRow({required this.line});

  final RegistryLine line;

  @override
  Widget build(BuildContext context) {
    final p = t.portal.picking;
    final muted = RegularTextStyles().regularInter12.copyWith(
      color: AppColors.kTextMuted,
    );
    final warn = RegularTextStyles().regularInter12.copyWith(
      color: AppColors.kBadgeWarningText,
    );
    final batch = line.batchDate;
    final available = line.available;
    return Padding(
      padding: AppInsets.all12,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            p.lineGood(code: line.goodCode, name: line.goodName),
            style: RegularTextStyles().regularInter13.copyWith(
              color: AppColors.kTextMain,
            ),
          ),
          if (!line.known) Text(p.lineUnknown, style: warn),
          Text(p.lineQty(qty: line.qty), style: muted),
          Text(
            batch == null ? p.lineNoBatch : p.lineBatch(date: fullDate(batch)),
            style: muted,
          ),
          if (line.cell.isNotEmpty)
            Text(
              line.cellFound
                  ? p.lineCell(cell: line.cell)
                  : p.lineCellMissing(cell: line.cell),
              style: line.cellFound ? muted : warn,
            ),
          if (available != null)
            Text(
              p.lineAvailable(qty: fmtQty(available)),
              style: line.shortage ? warn : muted,
            ),
        ],
      ),
    );
  }
}
