import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/di/injection.dart';
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
      create: (_) => getIt<StockEntryCubit>(),
      child: const _StockEntryView(),
    );
  }
}

/// Каркас экрана: шапка + busy-оверлей + тело по состоянию; снекбар ошибок через BlocListener.
class _StockEntryView extends StatelessWidget {
  const _StockEntryView();

  @override
  Widget build(BuildContext context) {
    return SystemUiWrapper(
      style: StatusBarStyle.dark,
      child: BlocListener<StockEntryCubit, StockEntryState>(
        listenWhen: (p, c) => c.failure != null && p.failure != c.failure,
        listener: (context, state) {
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(
              SnackBar(
                content: Text(
                  t.stockEntry.error(message: stockEntryFailureText(state.failure!)),
                ),
              ),
            );
          context.read<StockEntryCubit>().clearFailure();
        },
        child: Scaffold(
          appBar: AppBar(
            automaticallyImplyLeading: false,
            title: PageHeader(
              title: t.stockEntry.title,
              goBack: () => context.router.maybePop(),
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
