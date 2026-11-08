import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/utils/doc_number.dart';
import '../../../../core/widgets/error_retry.dart';
import '../../../../core/widgets/neumorphic_action_button.dart';
import '../../../../core/widgets/neumorphic_line_tile.dart';
import '../bloc/picking_shipped_cubit.dart';
import 'picking_format.dart';

/// Вкладка «Завершённые» «СБОРКИ»: дата накладной сверху (касание - календарь), под ней
/// отгруженные заказы этой даты. Касание заказа - его короба ([onOpen]).
class PickingShippedView extends StatelessWidget {
  const PickingShippedView({super.key, required this.onOpen});

  final void Function(String id, int number) onOpen;

  static String _fmt(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';

  Future<void> _pickDate(BuildContext context, DateTime current) async {
    final cubit = context.read<PickingShippedCubit>();
    final picked = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(2026),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked != null) await cubit.setDate(picked);
  }

  @override
  Widget build(BuildContext context) {
    final muted = RegularTextStyles().regularInter14.copyWith(
      color: AppColors.kTextMuted,
    );
    return BlocBuilder<PickingShippedCubit, PickingShippedState>(
      builder: (context, state) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: AppInsets.h8,
            child: NeumorphicActionButton(
              label: t.picking.shippedDate(date: _fmt(state.date)),
              icon: MdiIcons.calendarMonthOutline,
              onPressed: () => _pickDate(context, state.date),
            ),
          ),
          AppBoxes.kHeight8,
          Expanded(
            child: switch (state.status) {
              PickingShippedStatus.loading => const Center(
                child: CircularProgressIndicator(),
              ),
              PickingShippedStatus.error => ErrorRetry(
                onRetry: context.read<PickingShippedCubit>().load,
              ),
              PickingShippedStatus.loaded when state.orders.isEmpty => Padding(
                padding: AppInsets.h8,
                child: Text(t.picking.shippedEmpty, style: muted),
              ),
              PickingShippedStatus.loaded => ListView(
                padding: AppInsets.h8,
                children: [
                  for (final o in state.orders)
                    Padding(
                      padding: AppInsets.bottom8,
                      child: NeumorphicLineTile(
                        title: docNumber(DocKind.picking, o.number),
                        subtitle: listItemLines(o).join('\n'),
                        onTap: () => onOpen(o.id, o.number),
                      ),
                    ),
                ],
              ),
            },
          ),
        ],
      ),
    );
  }
}
