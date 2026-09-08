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
  /// финала, поэтому «назад» разбирается по состоянию прохода:
  /// - в ячейке → возврат к списку ячеек (`finishCell`, работа ячейки сохраняется), не выход;
  /// - на списке с непустым просчётом → выход, проход остаётся сохранённым;
  /// - пусто / после финала / идёт финал → штатный выход (или ничего).
  ///
  /// **Выход НЕ уничтожает проход** (ADHOC-13). Прежде здесь стоял диалог «просчитанные ячейки
  /// не сохранены и будут потеряны», и по подтверждению слепок стирался. Текст был неправдой с
  /// момента P2-03: ячейки сохранены, проход переживает и перезапуск, и разрядку батареи. То
  /// есть приложение предлагало уничтожить единственную копию работы кладовщика за обычное
  /// нажатие «назад», объясняя это несуществующей причиной. Отбрасывание стало отдельным
  /// действием в меню шапки.
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
    if (s.committedCells.isNotEmpty) {
      // Говорим, что работа не пропала: без этого выход выглядит так же, как прежняя потеря.
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(t.stockEntry.passKept)));
    }
    Navigator.of(context).pop();
  }

  /// Отбросить проход по явному требованию — единственный способ потерять его намеренно.
  Future<void> _onDiscard(BuildContext context) async {
    final cubit = context.read<StockEntryCubit>();
    if (!await _confirmDiscard(context)) return;
    await cubit.discardPass();
    if (context.mounted) Navigator.of(context).pop();
  }

  /// Диалог подтверждения отбрасывания прохода — действие необратимо.
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
                // Отбрасывание — редкое и необратимое действие, поэтому в меню, а не кнопкой
                // рядом с «Завершить ввод»: там его задели бы случайно.
                trailing: BlocBuilder<StockEntryCubit, StockEntryState>(
                  buildWhen: (p, c) =>
                      p.committedCells.isEmpty != c.committedCells.isEmpty ||
                      p.finished != c.finished,
                  builder: (context, state) =>
                      state.committedCells.isEmpty || state.finished
                      ? const SizedBox.shrink()
                      : PopupMenuButton<void>(
                          icon: const Icon(
                            Icons.more_vert,
                            color: AppColors.kNeumorphicBg,
                          ),
                          itemBuilder: (context) => [
                            PopupMenuItem<void>(
                              onTap: () => _onDiscard(context),
                              child: Text(t.stockEntry.discardMenu),
                            ),
                          ],
                        ),
                ),
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
