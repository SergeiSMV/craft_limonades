import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/gen/assets.gen.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/widgets/page_header.dart';
import '../../../../core/widgets/system_ui_wrapper.dart';
import '../bloc/receipt_cubit.dart';
import '../widgets/receipt_failure_text.dart';
import '../widgets/receipt_finished_view.dart';
import '../widgets/receipt_work_view.dart';
import '../widgets/supplier_select_view.dart';

/// Экран-поток приёмки на ТСД (P4-09): поставщик → строки (короба и штучно) → завершение.
@RoutePage()
class ReceiptPage extends StatelessWidget {
  const ReceiptPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      // restore() поднимает незавершённую приёмку, если приложение умерло до отправки.
      create: (_) => getIt<ReceiptCubit>()..restore(),
      child: const _ReceiptView(),
    );
  }
}

/// Каркас: шапка, busy-оверлей, тело по состоянию; снекбар ошибок через BlocListener.
class _ReceiptView extends StatelessWidget {
  const _ReceiptView();

  /// «Назад» (стрелка и системный жест). Выход приёмку НЕ теряет: черновик сохранён и
  /// поднимется при следующем открытии — об этом и говорим, чтобы выход не выглядел потерей
  /// (урок ADHOC-13).
  Future<void> _onBack(BuildContext context) async {
    final cubit = context.read<ReceiptCubit>();
    // Марки ЧЗ, отсканированные последними, сначала ложатся в черновик (ADHOC-70).
    if (cubit.czHold.busy) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(t.czScan.settling)));
      await cubit.czHold.settle();
      if (!context.mounted) return;
    }
    final s = cubit.state;
    if (s.busy) return; // идёт отправка — не мешаем
    if (s.started && s.outcome == null && s.lines.isNotEmpty) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(t.receipt.kept)));
    }
    Navigator.of(context).pop();
  }

  /// Отбросить приёмку по явному требованию — единственный способ потерять её намеренно.
  Future<void> _onDiscard(BuildContext context) async {
    final cubit = context.read<ReceiptCubit>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: Text(t.receipt.discardTitle),
        content: Text(t.receipt.discardBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(false),
            child: Text(t.receipt.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dctx).pop(true),
            child: Text(t.receipt.discardConfirm),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await cubit.discard();
    if (context.mounted) Navigator.of(context).pop();
  }

  /// Показать ошибку и сбросить её в состоянии.
  void _onFailure(BuildContext context, ReceiptState state) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            t.receipt.error(message: receiptFailureText(state.failure!)),
          ),
        ),
      );
    context.read<ReceiptCubit>().clearFailure();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_onBack(context));
      },
      child: SystemUiWrapper(
        style: StatusBarStyle.light,
        child: BlocListener<ReceiptCubit, ReceiptState>(
          listenWhen: (p, c) => c.failure != null && p.failure != c.failure,
          listener: _onFailure,
          child: Scaffold(
            backgroundColor: AppColors.kNeumorphicBg,
            appBar: AppBar(
              automaticallyImplyLeading: false,
              backgroundColor: Colors.transparent,
              elevation: 0,
              toolbarHeight: AppSizes.kIcon60,
              flexibleSpace: ClipRRect(
                borderRadius: AppBorders.kBottom10,
                child: Assets.images.featuredSnacks.image(fit: BoxFit.cover),
              ),
              title: PageHeader(
                title: t.receipt.title,
                goBack: () => _onBack(context),
                // Отбрасывание — редкое и необратимое, поэтому в меню, а не кнопкой рядом
                // с «Завершить приёмку».
                trailing: BlocBuilder<ReceiptCubit, ReceiptState>(
                  buildWhen: (p, c) =>
                      p.started != c.started || p.outcome != c.outcome,
                  builder: (context, state) =>
                      !state.started || state.outcome != null
                      ? const SizedBox.shrink()
                      : PopupMenuButton<void>(
                          icon: const Icon(
                            Icons.more_vert,
                            color: AppColors.kNeumorphicBg,
                          ),
                          itemBuilder: (context) => [
                            PopupMenuItem<void>(
                              onTap: () => _onDiscard(context),
                              child: Text(t.receipt.discardMenu),
                            ),
                          ],
                        ),
                ),
              ),
            ),
            body: Stack(
              children: [
                const _Body(),
                BlocBuilder<ReceiptCubit, ReceiptState>(
                  buildWhen: (p, c) => p.busy != c.busy,
                  builder: (context, state) => state.busy
                      ? const ColoredBox(
                          color: Colors.black26,
                          child: Center(child: CircularProgressIndicator()),
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Тело по состоянию: итог / выбор поставщика / работа.
class _Body extends StatelessWidget {
  const _Body();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<ReceiptCubit>().state;
    final outcome = state.outcome;
    if (outcome != null) {
      return ReceiptFinishedView(
        outcome: outcome,
        positions: state.lines.length,
        rejectReason: state.rejectReason,
      );
    }
    if (!state.started) return const SupplierSelectView();
    return ReceiptWorkView(state: state);
  }
}
