import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import '../../../../../core/constants/app_boxes.dart';
import '../../../../../core/constants/app_colors.dart';
import '../../../../../core/constants/app_insets.dart';
import '../../../../../core/constants/app_sizes.dart';
import '../../../../../core/gen/strings.g.dart';
import '../../../../../core/theme/semibold_text.dart';
import '../../bloc/stock_detail_cubit.dart';
import 'expandable_card.dart';

/// Секция «Штрихкоды (N)» карточки товара (P-FS-12): раскрывающийся список привязанных ШК
/// с отвязкой ошибочного (крестик справа, с подтверждением).
///
/// Не показывается совсем, если ШК не привязаны или карточка ещё грузится: пустой блок
/// на экране ТСД только занимает место, а число в заголовке до загрузки врало бы.
class BarcodesSection extends StatelessWidget {
  const BarcodesSection({super.key});

  /// Подтвердить и отвязать ШК от товара.
  Future<void> confirmUnbind(BuildContext context, String code) async {
    final cubit = context.read<StockDetailCubit>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: Text(t.stockDetailScreen.barcodeDeleteTitle),
        content: Text(t.stockDetailScreen.barcodeDeleteBody(barcode: code)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(false),
            child: Text(t.stockDetailScreen.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dctx).pop(true),
            child: Text(t.stockDetailScreen.unbind),
          ),
        ],
      ),
    );
    if (ok == true) cubit.unbindBarcode(code);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<StockDetailCubit>().state;
    if (state.status != StockDetailStatus.loaded || state.barcodes.isEmpty) {
      return const SizedBox.shrink();
    }

    // Отступ до следующей секции держим внутри блока: когда ШК нет и блок скрыт,
    // лишнего зазора на экране не остаётся.
    return Padding(
      padding: AppInsets.bottom16,
      child: ExpandableCard(
        headerBuilder: (_) => Padding(
          padding: AppInsets.top4,
          child: Text(
            t.stockDetailScreen.barcodesTitle(count: state.barcodes.length),
            style: SemiboldTextStyles().semiboldInter14.copyWith(
              color: AppColors.kTextMain,
            ),
          ),
        ),
        child: Column(
          children: [
            for (var i = 0; i < state.barcodes.length; i++) ...[
              if (i > 0)
                const Padding(
                  padding: AppInsets.h16,
                  child: Divider(height: 1, color: AppColors.kBorder),
                ),
              _BarcodeRow(
                barcode: state.barcodes[i].barcode,
                onUnbind: () =>
                    confirmUnbind(context, state.barcodes[i].barcode),
              ),
            ],
            AppBoxes.kHeight8,
          ],
        ),
      ),
    );
  }
}

/// Строка штрихкода: иконка-плашка ШК, сам код и крестик отвязки.
class _BarcodeRow extends StatelessWidget {
  const _BarcodeRow({required this.barcode, required this.onUnbind});

  /// Значение штрихкода.
  final String barcode;

  /// Отвязать этот ШК от товара (с подтверждением).
  final VoidCallback onUnbind;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: AppInsets.h8 + AppInsets.v4,
      child: Row(
        children: [
          Padding(
            padding: AppInsets.left10,
            child: Icon(
              MdiIcons.barcode,
              size: AppSizes.kIcon25,
              color: AppColors.kTextMuted,
            ),
          ),
          AppBoxes.kWidth8,
          Expanded(
            child: Text(
              barcode,
              style: SemiboldTextStyles().semiboldInter14.copyWith(
                color: AppColors.kTextMain,
              ),
            ),
          ),
          IconButton(
            onPressed: onUnbind,
            icon: const Icon(
              Icons.close,
              size: AppSizes.kIcon20,
              color: AppColors.kTextMuted,
            ),
          ),
        ],
      ),
    );
  }
}
