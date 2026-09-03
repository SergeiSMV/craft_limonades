import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/gen/assets.gen.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/widgets/page_header.dart';
import '../../../../core/widgets/system_ui_wrapper.dart';
import '../bloc/stock_entry_cubit.dart';
import '../widgets/cell_entry_view.dart';
import '../widgets/cell_select_view.dart';
import '../widgets/failure_text.dart';
import '../widgets/finished_view.dart';

/// Экран-поток ввода стартовых остатков (P-FastStart, ТСД). Один экран со стейт-машиной:
/// выбор ячейки → буфер строк ячейки → завершение ячейки → следующая ячейка → завершение ввода.
/// Крупные части вынесены в `widgets/` (выбор ячейки, работа с ячейкой, финал, диалоги/листы).
@RoutePage()
class StockEntryPage extends StatelessWidget {
  const StockEntryPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      // restore() поднимает незавершённый проход, если приложение умерло до финала (P2-03).
      create: (_) => getIt<StockEntryCubit>()..restore(),
      child: const _StockEntryView(),
    );
  }
}

/// Каркас экрана: шапка + busy-оверлей + тело по состоянию; снекбар ошибок через BlocListener.
class _StockEntryView extends StatelessWidget {
  const _StockEntryView();

  /// Единая обработка «назад» (кнопка в шапке и системный жест/кнопка). Вариант A — всё в памяти до
  /// финала, поэтому защищаем от случайной потери прохода:
  /// - в ячейке → возврат к списку ячеек (`finishCell`, работа ячейки сохраняется), не выход;
  /// - на списке с непустым просчётом → подтверждение выхода (иначе потеря);
  /// - пусто / после финала / идёт финал → штатный выход (или ничего).
  Future<void> _onBack(BuildContext context) async {
    final cubit = context.read<StockEntryCubit>();
    final s = cubit.state;
    if (s.busy) return; // идёт финал — не мешаем
    if (s.finished) {
      Navigator.of(context).pop();
      return;
    }
    if (s.cell != null) {
      cubit.finishCell(); // назад к списку ячеек — просчёт ячейки сохраняется
      return;
    }
    if (s.committedCells.isEmpty) {
      Navigator.of(context).pop();
      return;
    }
    final leave = await _confirmDiscard(context);
    if (!leave) return;
    // Кладовщик подтвердил потерю просчёта — забываем и сохранённый слепок, иначе
    // следующее открытие экрана подняло бы брошенный проход (P2-03).
    await cubit.discardDraft();
    if (context.mounted) Navigator.of(context).pop();
  }

  /// Диалог подтверждения выхода с несохранённым просчётом.
  Future<bool> _confirmDiscard(BuildContext context) async {
    final res = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: Text(t.stockEntry.discardTitle),
        content: Text(t.stockEntry.discardBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(false),
            child: Text(t.stockEntry.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dctx).pop(true),
            child: Text(t.stockEntry.discardConfirm),
          ),
        ],
      ),
    );
    return res ?? false;
  }

  @override
  Widget build(BuildContext context) {
    // canPop: false — перехватываем и системный «назад», и стрелку в шапке единым [_onBack].
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _onBack(context);
      },
      child: SystemUiWrapper(
      style: StatusBarStyle.light,
      child: BlocListener<StockEntryCubit, StockEntryState>(
        listenWhen: (p, c) => c.failure != null && p.failure != c.failure,
        listener: (context, state) {
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(
              SnackBar(
                content: Text(
                  t.stockEntry.error(
                    message: stockEntryFailureText(state.failure!),
                  ),
                ),
              ),
            );
          context.read<StockEntryCubit>().clearFailure();
        },
        child: Scaffold(
          backgroundColor: AppColors.kNeumorphicBg,
          appBar: AppBar(
            automaticallyImplyLeading: false,
            backgroundColor: Colors.transparent,
            elevation: 0,
            toolbarHeight: AppSizes.kIcon60,
            flexibleSpace: ClipRRect(
              borderRadius: const BorderRadius.only(
                bottomLeft: Radius.circular(10),
                bottomRight: Radius.circular(10),
              ),
              child: Assets.images.stockEntry.image(fit: BoxFit.cover),
            ),
            title: PageHeader(
              title: t.stockEntry.title,
              goBack: () => _onBack(context),
            ),
          ),
          body: Stack(
            children: [
              const _Body(),
              BlocBuilder<StockEntryCubit, StockEntryState>(
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

/// Тело: финальный экран / выбор ячейки / работа с ячейкой — по состоянию.
class _Body extends StatelessWidget {
  const _Body();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<StockEntryCubit>().state;
    if (state.finished) {
      return FinishedView(written: state.written);
    }
    if (state.cell == null) {
      return CellSelectView(committed: state.committedCells);
    }
    return CellEntryView(state: state);
  }
}
