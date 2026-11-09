import 'package:flutter/material.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/error/failure.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/utils/doc_number.dart';
import '../../../../core/widgets/neumorphic_line_tile.dart';
import '../../../../core/widgets/section_title.dart';
import '../../domain/picking_models.dart';
import '../bloc/picking_list_cubit.dart';
import 'picking_format.dart';

/// Список заказов «СБОРКА» (P9-06): свои, свободные, у других; без связи - открытые на
/// терминале.
class PickingOrdersList extends StatelessWidget {
  const PickingOrdersList({
    super.key,
    required this.state,
    required this.onRetry,
    required this.onOpen,
    required this.onOpenPicked,
  });

  final PickingListState state;
  final Future<void> Function() onRetry;
  final void Function(String id, int number) onOpen;

  /// Открыть собранный заказ - ярлыки и отгрузка (P9-07).
  final void Function(String id, int number) onOpenPicked;

  @override
  Widget build(BuildContext context) {
    final muted = RegularTextStyles().regularInter14.copyWith(
      color: AppColors.kTextMuted,
    );
    if (state.status == PickingListStatus.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final loaded = state.status == PickingListStatus.loaded;
    return RefreshIndicator(
      onRefresh: onRetry,
      child: ListView(
        padding: AppInsets.h8,
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          if (!loaded) ...[
            Text(
              state.failure is NetworkFailure
                  ? t.picking.offline
                  : t.picking.loadFailed,
              style: muted.copyWith(color: AppColors.kBadgeWarningText),
            ),
            AppBoxes.kHeight8,
            if (state.onTerminal.isNotEmpty) ...[
              SectionTitle(title: t.picking.sectionTerminal),
              for (final v in state.onTerminal)
                _tile(
                  number: v.order.number,
                  lines: orderLines(
                    invoiceNumber: v.order.invoiceNumber,
                    orderNumber: v.order.orderNumber,
                    client: v.order.client,
                    direction: v.order.direction,
                    registryDate: v.order.registryDate,
                  ),
                  onTap: () => onOpen(v.order.id, v.order.number),
                ),
            ],
          ],
          if (loaded) ...[
            if (state.orders.isEmpty) Text(t.picking.empty, style: muted),
            if (state.mine.isNotEmpty) ...[
              SectionTitle(title: t.picking.sectionMine),
              for (final o in state.mine) _item(o),
            ],
            if (state.free.isNotEmpty) ...[
              SectionTitle(title: t.picking.sectionFree),
              for (final o in state.free) _item(o),
            ],
            if (state.busy.isNotEmpty) ...[
              SectionTitle(title: t.picking.sectionBusy),
              for (final o in state.busy) _item(o),
            ],
            if (state.picked.isNotEmpty) ...[
              SectionTitle(title: t.picking.sectionPicked),
              for (final o in state.picked) _item(o),
            ],
          ],
          AppBoxes.kHeight8,
        ],
      ),
    );
  }

  Widget _item(PickingListItem o) => _tile(
    number: o.number,
    lines: listItemLines(o),
    onTap: () =>
        o.picked ? onOpenPicked(o.id, o.number) : onOpen(o.id, o.number),
  );

  Widget _tile({
    required int number,
    required List<String> lines,
    required VoidCallback onTap,
  }) => Padding(
    padding: AppInsets.bottom8,
    child: NeumorphicLineTile(
      title: docNumber(DocKind.picking, number),
      subtitle: lines.join('\n'),
      onTap: onTap,
    ),
  );
}
