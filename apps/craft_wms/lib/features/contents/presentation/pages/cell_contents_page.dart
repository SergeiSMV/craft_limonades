import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/router/app_router.dart';
import '../../../../core/scanner/hardware_scan_listener.dart';
import '../../../../core/scanner/scan_code.dart';
import '../../../../core/widgets/page_header.dart';
import '../../../../core/widgets/system_ui_wrapper.dart';
import '../../domain/contents_entities.dart';
import '../bloc/cell_contents_cubit.dart';
import '../contents_navigation.dart';
import '../widgets/cell/cell_contents_body.dart';
import '../widgets/common/contents_state_view.dart';

/// Экран «Ячейка» (P5-05): что лежит в ячейке — короба и россыпь. Открывается сканом этикетки
/// ячейки в «Остатках»; скан короба или другой ячейки отсюда открывает их.
@RoutePage()
class CellContentsPage extends StatelessWidget {
  const CellContentsPage({
    super.key,
    required this.cellId,
    required this.address,
  });

  final String cellId;
  final String address;

  @override
  Widget build(BuildContext context) {
    final cell = CellRef(id: cellId, address: address);
    return BlocProvider(
      create: (_) => getIt<CellContentsCubit>()..load(cell),
      child: _CellContentsView(cell: cell),
    );
  }
}

class _CellContentsView extends StatefulWidget {
  const _CellContentsView({required this.cell});

  final CellRef cell;

  @override
  State<_CellContentsView> createState() => _CellContentsViewState();
}

class _CellContentsViewState extends State<_CellContentsView>
    with HardwareScanListener {
  /// Скан с экрана ячейки: короб — его карточка поверх, другая ячейка — вместо этой.
  @override
  Future<void> onHardwareScan(ScanCode code) async {
    final replace = code.kind == ScanKind.cell;
    final handled = await openScannedContents(context, code, replace: replace);
    if (!handled && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(t.contents.notCellOrBox)));
    }
  }

  /// Перечитать содержимое ячейки.
  Future<void> reload() => context.read<CellContentsCubit>().load(widget.cell);

  /// Открыть карточку короба из списка ячейки.
  void openLoadUnit(LoadUnitView loadUnit) =>
      context.router.push(LoadUnitRoute(loadUnitId: loadUnit.id));

  @override
  Widget build(BuildContext context) {
    final state = context.watch<CellContentsCubit>().state;
    return SystemUiWrapper(
      child: Scaffold(
        backgroundColor: AppColors.kBg,
        appBar: AppBar(
          automaticallyImplyLeading: false,
          backgroundColor: AppColors.kBg,
          title: PageHeader(
            title: t.contents.cellTitle,
            textColor: AppColors.kSidebarHover,
            goBack: () => Navigator.of(context).pop(),
          ),
        ),
        body: ContentsStateView<CellView>(
          state: state,
          onRetry: reload,
          builder: (data) => CellContentsBody(
            data: data,
            onRefresh: reload,
            onOpenLoadUnit: openLoadUnit,
          ),
        ),
      ),
    );
  }
}
