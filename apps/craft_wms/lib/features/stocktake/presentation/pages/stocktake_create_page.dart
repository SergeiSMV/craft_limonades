import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/error/failure_reason.dart';
import '../../../../core/gen/assets.gen.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/scanner/hardware_scan_listener.dart';
import '../../../../core/scanner/scan_code.dart';
import '../../../../core/scanner/scan_deduper.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/warehouse/internal_warehouses.dart';
import '../../../../core/widgets/neumorphic_action_button.dart';
import '../../../../core/widgets/neumorphic_choice.dart';
import '../../../../core/widgets/neumorphic_line_tile.dart';
import '../../../../core/widgets/page_header.dart';
import '../../../../core/widgets/scan_field.dart';
import '../../../../core/widgets/section_title.dart';
import '../../../../core/widgets/system_ui_wrapper.dart';
import '../../../stock/domain/catalog_repository.dart';
import '../../domain/stocktake_models.dart';
import '../bloc/stocktake_create_cubit.dart';
import '../widgets/stocktake_format.dart';
import '../../../../core/utils/doc_number.dart';

/// Новый пересчёт с ТСД (P10-04) - старшему смены (пока admin): ячейки сканом, внутренний
/// склад или весь склад. Сложные области (группы, матрицы, поставщики, товары) - в портале.
@RoutePage()
class StocktakeCreatePage extends StatelessWidget {
  const StocktakeCreatePage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => getIt<StocktakeCreateCubit>(),
      child: const _CreateView(),
    );
  }
}

class _CreateView extends StatefulWidget {
  const _CreateView();

  @override
  State<_CreateView> createState() => _CreateViewState();
}

class _CreateViewState extends State<_CreateView> with HardwareScanListener {
  final _scanController = TextEditingController();
  final _scanFocus = FocusNode();
  final _deduper = ScanDeduper();

  /// Внутренние склады, которые можно выбрать: активные, не системные.
  List<InternalWarehouse> _warehouses = const [];

  StocktakeCreateCubit get cubit => context.read<StocktakeCreateCubit>();

  @override
  void initState() {
    super.initState();
    _loadWarehouses();
  }

  Future<void> _loadWarehouses() async {
    final all = await getIt<InternalWarehouses>().all();
    if (mounted) {
      setState(
        () => _warehouses = [
          for (final w in all)
            if (w.isActive) w,
        ],
      );
    }
  }

  @override
  void dispose() {
    _scanController.dispose();
    _scanFocus.dispose();
    super.dispose();
  }

  @override
  void onHardwareScan(ScanCode code) => onScan(code.raw);

  /// Скан ячейки - в область «ячейки»: из справочника терминала, ячейка приёмки не входит.
  Future<void> onScan(String value) async {
    final code = value.trim();
    _scanController.clear();
    if (code.isEmpty || !_deduper.allow(code)) return;
    if (cubit.state.scopeKind != StocktakeScope.cells ||
        classifyScan(code) != ScanKind.cell) {
      snack(t.stocktake.createScanCells);
      return;
    }
    final res = await getIt<CatalogRepository>().listAllCells();
    if (!mounted) return;
    final a = code.toLowerCase();
    final cell = res.isRight
        ? res.right.where((c) => c.address.toLowerCase() == a).firstOrNull
        : null;
    if (cell == null) {
      snack(t.stocktake.createCellUnknown(address: code));
    } else if (cell.isDefault) {
      snack(t.stocktake.createReceiving);
    } else {
      cubit.addCell((id: cell.id, address: cell.address));
    }
    if (mounted) _scanFocus.requestFocus();
  }

  /// «Завести» на складе терминала - склад ячейки приёмки (один склад на терминал).
  Future<void> create() async {
    final res = await getIt<CatalogRepository>().defaultCell();
    if (!mounted) return;
    final warehouseId = res.isRight ? res.right?.warehouseId : null;
    if (warehouseId == null) {
      snack(t.stocktake.createNoWarehouse);
      return;
    }
    await cubit.create(warehouseId);
  }

  void goBack() => context.router.maybePop();

  void snack(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  /// Итог: заведён - назад к заданиям; отказ - причина.
  void onState(BuildContext context, StocktakeCreateState state) {
    if (state.created case final c?) {
      snack(t.stocktake.createDone(number: docNumber(DocKind.stocktake, c.number), cells: c.cells));
      goBack();
    } else if (state.failure case final f?) {
      snack(t.stocktake.createFailed(reason: failureReason(f)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<StocktakeCreateCubit, StocktakeCreateState>(
      listenWhen: (a, b) =>
          (b.created != null && a.created != b.created) ||
          (b.failure != null && a.failure != b.failure),
      listener: onState,
      builder: (context, state) => SystemUiWrapper(
        style: StatusBarStyle.light,
        child: Scaffold(
          resizeToAvoidBottomInset: false,
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
            title: PageHeader(title: t.stocktake.createTitle, goBack: goBack),
          ),
          body: SafeArea(
            top: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: _form(state)),
                Padding(
                  padding: AppInsets.all16,
                  child: NeumorphicActionStack(
                    buttons: [
                      NeumorphicActionButton(
                        label: t.stocktake.createSubmit,
                        icon: MdiIcons.clipboardPlusOutline,
                        onPressed: state.ready && !state.busy ? create : () {},
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _form(StocktakeCreateState state) {
    final muted = RegularTextStyles().regularInter14.copyWith(
      color: AppColors.kTextMuted,
    );
    return ListView(
      padding: AppInsets.h8 + AppInsets.v16,
      children: [
        SectionTitle(title: t.stocktake.createScope),
        Wrap(
          spacing: AppSizes.kChipSpacing,
          runSpacing: AppSizes.kChipSpacing,
          children: [
            for (final kind in const [
              StocktakeScope.cells,
              StocktakeScope.internalWarehouse,
              StocktakeScope.all,
            ])
              NeumorphicChoice(
                label: scopeLabel(kind),
                selected: state.scopeKind == kind,
                onPressed: () => cubit.selectScope(kind),
              ),
          ],
        ),
        AppBoxes.kHeight8,
        Text(t.stocktake.createPortalHint, style: muted),
        AppBoxes.kHeight16,
        ...switch (state.scopeKind) {
          StocktakeScope.cells => [
            ScanField(
              controller: _scanController,
              focusNode: _scanFocus,
              hint: t.stocktake.createScanCells,
              onSubmitted: onScan,
            ),
            AppBoxes.kHeight8,
            if (state.cells.isEmpty)
              Text(t.stocktake.createCellsEmpty, style: muted),
            for (final c in state.cells)
              Padding(
                padding: AppInsets.bottom8,
                child: NeumorphicLineTile(
                  title: c.address,
                  trailing: t.stocktake.lineRemove,
                  onTap: () => cubit.removeCell(c),
                ),
              ),
          ],
          StocktakeScope.internalWarehouse => [
            SectionTitle(title: t.stocktake.createWarehouse),
            Wrap(
              spacing: AppSizes.kChipSpacing,
              runSpacing: AppSizes.kChipSpacing,
              children: [
                for (final w in _warehouses)
                  NeumorphicChoice(
                    label: w.name,
                    selected: state.internalWarehouseId == w.id,
                    onPressed: () => cubit.selectWarehouse(w.id),
                  ),
              ],
            ),
          ],
          _ => [Text(t.stocktake.createAllHint, style: muted)],
        },
      ],
    );
  }
}
