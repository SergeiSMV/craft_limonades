import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/printer/load_unit_label.dart';
import '../../../../core/scanner/hardware_scan_listener.dart';
import '../../../../core/scanner/scan_code.dart';
import '../../../../core/widgets/page_header.dart';
import '../../../../core/widgets/system_ui_wrapper.dart';
import '../../../stock/presentation/stock_navigation.dart';
import '../../domain/contents_entities.dart';
import '../bloc/load_unit_cubit.dart';
import '../bloc/load_unit_history_cubit.dart';
import '../contents_navigation.dart';
import '../widgets/common/contents_state_view.dart';
import '../widgets/load_unit/history_section.dart';
import '../widgets/load_unit/load_unit_body.dart';

/// Экран «Короб» (P5-05): где лежит и что внутри. Открывается сканом QR короба в «Остатках»
/// или касанием короба в списке ячейки; скан другого короба или ячейки отсюда открывает их.
/// С P5-05-1 — перепечатка ярлыка и история короба.
@RoutePage()
class LoadUnitPage extends StatelessWidget {
  const LoadUnitPage({super.key, required this.loadUnitId});

  /// Идентификатор из QR ярлыка.
  final String loadUnitId;

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider(create: (_) => getIt<LoadUnitCubit>()..load(loadUnitId)),
        BlocProvider(
          create: (_) => getIt<LoadUnitHistoryCubit>()..load(loadUnitId),
        ),
      ],
      child: _LoadUnitView(loadUnitId: loadUnitId),
    );
  }
}

class _LoadUnitView extends StatefulWidget {
  const _LoadUnitView({required this.loadUnitId});

  final String loadUnitId;

  @override
  State<_LoadUnitView> createState() => _LoadUnitViewState();
}

class _LoadUnitViewState extends State<_LoadUnitView>
    with HardwareScanListener {
  /// Скан с экрана короба: другой короб или ячейка — вместо этого экрана, без стопки.
  @override
  Future<void> onHardwareScan(ScanCode code) async {
    final handled = await openScannedContents(context, code, replace: true);
    if (!handled && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(t.contents.notCellOrBox)));
    }
  }

  /// Идёт печать ярлыка — кнопка не принимает повторное нажатие.
  bool _printing = false;

  /// Перечитать карточку и историю короба.
  Future<void> reload() async {
    final history = context.read<LoadUnitHistoryCubit>();
    await context.read<LoadUnitCubit>().load(widget.loadUnitId);
    await history.load(widget.loadUnitId);
  }

  /// Открыть карточку остатков товара из содержимого короба.
  void openGood(ContentLine line) => openGoodCard(
    context,
    goodId: line.goodId,
    name: line.goodName ?? t.contents.unknownGood,
    code: line.goodCode,
    uom: line.uom,
  );

  /// Перепечатать ярлык и сказать, чем кончилось.
  Future<void> reprint() async {
    setState(() => _printing = true);
    final error = await context.read<LoadUnitCubit>().reprint(
      widget.loadUnitId,
    );
    if (!mounted) return;
    setState(() => _printing = false);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(error ?? t.contents.reprinted)));
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<LoadUnitCubit>().state;
    return SystemUiWrapper(
      child: Scaffold(
        backgroundColor: AppColors.kBg,
        appBar: AppBar(
          automaticallyImplyLeading: false,
          backgroundColor: AppColors.kBg,
          title: PageHeader(
            // Код короба — в заголовке: он известен из QR до всякой загрузки (ADHOC-21).
            title: t.contents.boxCode(
              code: LoadUnitLabel(widget.loadUnitId).shortCodeFormatted,
            ),
            textColor: AppColors.kSidebarHover,
            goBack: () => Navigator.of(context).pop(),
          ),
        ),
        body: ContentsStateView<LoadUnitView>(
          state: state,
          onRetry: reload,
          builder: (data) => LoadUnitBody(
            data: data,
            onRefresh: reload,
            reprintBusy: _printing,
            onReprint: reprint,
            onOpenGood: openGood,
            history: const HistorySection(),
          ),
        ),
      ),
    );
  }
}
