import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import '../../../../../core/constants/app_boxes.dart';
import '../../../../../core/constants/app_colors.dart';
import '../../../../../core/constants/app_insets.dart';
import '../../../../../core/constants/app_sizes.dart';
import '../../../../../core/di/injection.dart';
import '../../../../../core/gen/strings.g.dart';
import '../../../../../core/printer/printer_device.dart';
import '../../../../../core/printer/printer_service.dart';
import '../../../../../core/theme/regular_text.dart';
import '../../../../../core/theme/semibold_text.dart';
import '../../bloc/stock_detail_cubit.dart';
import 'bind_barcode_button.dart';
import 'bind_barcode_dialog.dart';
import 'regrade_flow.dart';
import '../../../../../core/widgets/expandable_card.dart';

/// Секция «Штрихкоды (N)» карточки товара (P-FS-12): раскрывающийся список привязанных ШК
/// с отвязкой ошибочного (крестик справа, с подтверждением).
///
/// Пока карточка грузится, секции нет совсем: число в заголовке до загрузки врало бы.
/// Если ШК не привязано ни одного, вместо сворачиваемого блока — одна кнопка «Привязать
/// штрихкод +»: заголовок «Штрихкоды (0)» и пустой раскрывающийся список только занимали бы место.
class BarcodesSection extends StatelessWidget {
  const BarcodesSection({
    required this.goodId,
    required this.goodName,
    this.czMarked = false,
    super.key,
  });

  /// Товар карточки.
  final String goodId;

  /// Наименование товара — печатается на ярлыке рядом со штрихкодом: без него наклейка
  /// анонимна, и кладовщик не отличит одну от другой, пока не отсканирует.
  final String goodName;

  /// Маркируемый товар (CZ-05): перед отвязкой его ШК проверяются марки на складе (ADHOC-53).
  final bool czMarked;

  /// Напечатать товарный ярлык: штрихкод и наименование (P4-08).
  ///
  /// Печать и перепечать — одно действие: ярлык полностью определяется кодом и наименованием,
  /// и испорченную наклейку меняют на такую же. Отдельной кнопки «перепечатать» поэтому нет.
  ///
  /// Отложенную привязку печатать не даём: такого ШК на сервере ещё нет, и наклейка на товаре
  /// опередила бы справочник — отсканировали бы код, которого система не знает.
  Future<void> printLabel(BuildContext context, String code) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await getIt<PrinterService>().printGoodLabel(
        barcode: code,
        goodName: goodName,
      );
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text(t.stockDetailScreen.labelPrinted)),
        );
    } on PrinterFailure catch (e) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(e.userMessage)));
    }
  }

  /// Подтвердить и отвязать ШК от товара.
  ///
  /// У маркируемого товара сначала — марки на складе (ADHOC-53): есть — вместо отвязки
  /// перепривязка с пересортом ([RegradeFlow]).
  Future<void> confirmUnbind(BuildContext context, String code) async {
    final cubit = context.read<StockDetailCubit>();
    if (czMarked) {
      final flow = RegradeFlow(context, goodId: goodId, goodName: goodName);
      final free = await flow.canUnbind(
        code,
        onRegraded: () => cubit.load(goodId),
      );
      if (!free || !context.mounted) return;
    }
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

  /// Открыть диалог привязки ШК.
  ///
  /// После успеха карточку перезагружает сам cubit, доделывать нечего. А вот отложенную
  /// привязку сообщить надо: диалог закрылся, на карточке ничего не изменилось, и без
  /// сообщения кладовщик не поймёт, принята его работа или потеряна (ADHOC-11).
  Future<void> openBindDialog(BuildContext context) async {
    final cubit = context.read<StockDetailCubit>();
    final messenger = ScaffoldMessenger.of(context);
    final outcome = await showDialog<BindOutcome>(
      context: context,
      builder: (_) => BindBarcodeDialog(onBind: cubit.bindBarcode),
    );
    if (outcome != BindOutcome.deferred) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(t.stockDetailScreen.bindOffline)));
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<StockDetailCubit>().state;
    if (state.status != StockDetailStatus.loaded) {
      return const SizedBox.shrink();
    }

    if (state.barcodes.isEmpty) {
      return Padding(
        padding: AppInsets.bottom16,
        child: BindBarcodeButton(onPressed: () => openBindDialog(context)),
      );
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
                pending: state.barcodes[i].pending,
                onUnbind: () =>
                    confirmUnbind(context, state.barcodes[i].barcode),
                onPrint: state.barcodes[i].pending
                    ? null
                    : () => printLabel(context, state.barcodes[i].barcode),
              ),
            ],
            AppBoxes.kHeight8,
            Padding(
              padding: AppInsets.h8 + AppInsets.bottom8,
              child: BindBarcodeButton(
                onPressed: () => openBindDialog(context),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Строка штрихкода: иконка-плашка ШК, сам код и крестик отвязки.
class _BarcodeRow extends StatelessWidget {
  const _BarcodeRow({
    required this.barcode,
    required this.onUnbind,
    required this.onPrint,
    this.pending = false,
  });

  /// Значение штрихкода.
  final String barcode;

  /// Отвязать этот ШК от товара (с подтверждением).
  final VoidCallback onUnbind;

  /// Напечатать ярлык с этим ШК; `null` — печать недоступна (привязка ещё не на сервере).
  final VoidCallback? onPrint;

  /// Привязка сделана на устройстве и сервером ещё не подтверждена (P2-06).
  ///
  /// Показывать её наравне с подтверждёнными нельзя: кладовщик счёл бы дело сделанным, хотя
  /// операция ещё в очереди и может быть отклонена — тогда строка исчезнет сама.
  final bool pending;

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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  barcode,
                  style: SemiboldTextStyles().semiboldInter14.copyWith(
                    // Неподтверждённая привязка приглушена: она есть, но ещё не факт.
                    color: pending ? AppColors.kTextMuted : AppColors.kTextMain,
                  ),
                ),
                if (pending)
                  Text(
                    t.stockDetailScreen.barcodePending,
                    style: RegularTextStyles().regularInter12.copyWith(
                      color: AppColors.kTextMuted,
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            // Печать недоступна у неподтверждённой привязки: такого ШК на сервере ещё нет,
            // и наклейка на товаре опередила бы справочник.
            onPressed: onPrint,
            tooltip: t.stockDetailScreen.printLabel,
            icon: Icon(
              Icons.print_outlined,
              size: AppSizes.kIcon20,
              color: onPrint == null
                  ? AppColors.kTextMuted
                  : AppColors.kTextMain,
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
