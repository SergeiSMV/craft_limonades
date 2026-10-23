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
import '../../../../core/gen/assets.gen.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/load_unit/load_unit_code.dart';
import '../../../../core/scanner/hardware_scan_listener.dart';
import '../../../../core/scanner/scan_code.dart';
import '../../../../core/scanner/scan_deduper.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/utils/keyboard.dart';
import '../../../../core/widgets/cell_change_sheet.dart';
import '../../../../core/widgets/neumorphic_action_button.dart';
import '../../../../core/widgets/page_header.dart';
import '../../../../core/widgets/qty_dialog.dart';
import '../../../../core/widgets/scan_field.dart';
import '../../../../core/widgets/system_ui_wrapper.dart';
import '../../../../core/widgets/tab_switch.dart';
import '../../../contents/domain/contents_entities.dart';
import '../../../contents/domain/contents_repository.dart';
import '../../../movement/domain/movement_models.dart';
import '../../../movement/presentation/widgets/move_qty_header.dart';
import '../../../stock/data/catalog_models.dart';
import '../../../stock/data/catalog_repository.dart';
import '../../domain/problem_models.dart';
import '../bloc/current_problems_cubit.dart';
import '../bloc/problem_cubit.dart';
import '../bloc/problem_state.dart';
import '../bloc/resolved_problems_cubit.dart';
import '../widgets/current/current_problems_view.dart';
import '../widgets/problem_choice.dart';
import '../widgets/problem_form.dart';
import '../widgets/problem_outcome_view.dart';
import '../widgets/resolved/resolved_feed.dart';
import '../widgets/resolved/resolved_filter_button.dart';

/// «Проблемы склада» (P6-07-2): пометить короб или товар браком, изолятором … Одна проблема —
/// одна операция очереди; работает без связи. Скан короба или ячейки → короб целиком или
/// товар с количеством → склад → причина → комментарий → «Зафиксировать».
///
/// Вкладки «Текущие» / «Завершённые»: в первой — открытые проблемы всего склада и свои
/// неотправленные (ADHOC-35), внизу «Добавить» — фиксация новой открывается во весь экран;
/// во второй — решённые офисом в портале, лентой по дням (ADHOC-34). Скан короба или ячейки
/// со списка сразу начинает фиксацию.
@RoutePage()
class ProblemPage extends StatelessWidget {
  const ProblemPage({super.key});

  @override
  Widget build(BuildContext context) => MultiBlocProvider(
    providers: [
      BlocProvider(create: (_) => getIt<ProblemCubit>()..init()),
      BlocProvider(create: (_) => getIt<CurrentProblemsCubit>()..load()),
      BlocProvider(create: (_) => getIt<ResolvedProblemsCubit>()),
    ],
    child: const _ProblemView(),
  );
}

class _ProblemView extends StatefulWidget {
  const _ProblemView();

  @override
  State<_ProblemView> createState() => _ProblemViewState();
}

class _ProblemViewState extends State<_ProblemView> with HardwareScanListener {
  final _scanController = TextEditingController();
  final _scanFocus = FocusNode();
  final _comment = TextEditingController();
  final _mark = TextEditingController();
  final _deduper = ScanDeduper();

  /// Открытая вкладка: 0 — «Зафиксировать», 1 — «Завершённые».
  int _tab = 0;

  /// Идёт фиксация новой проблемы: форма во весь экран, без вкладок.
  bool _adding = false;

  ProblemCubit get cubit => context.read<ProblemCubit>();
  ContentsRepository get contents => getIt<ContentsRepository>();

  @override
  void initState() {
    super.initState();
    _comment.addListener(() => cubit.setComment(_comment.text));
    _mark.addListener(() => cubit.setMark(_mark.text));
  }

  @override
  void dispose() {
    _scanController.dispose();
    _scanFocus.dispose();
    _comment.dispose();
    _mark.dispose();
    super.dispose();
  }

  /// Вернуть фокус полю скана — иначе сканер в режиме «клавиатуры» печатает в никуда.
  void refocusScan() {
    if (mounted && _adding && cubit.state.subject == null) {
      _scanFocus.requestFocus();
    }
  }

  //* --- вкладки --- *//

  /// Переключить вкладку; ленту решённых грузим при первом заходе в «Завершённые».
  void selectTab(int index) {
    setState(() => _tab = index);
    final resolved = context.read<ResolvedProblemsCubit>();
    if (index == 1 && resolved.state.status == ResolvedStatus.initial) {
      resolved.load();
    }
  }

  /// «Добавить» — к фиксации новой проблемы; поле скана сразу ловит код.
  void startAdding() {
    setState(() => _adding = true);
    WidgetsBinding.instance.addPostFrameCallback((_) => refocusScan());
  }

  /// Фиксация окончена или отменена — к списку «Текущие», он перечитывается: в нём уже своя
  /// новая проблема. Форма очищается к следующему разу.
  void finishAdding() {
    _comment.clear();
    _mark.clear();
    cubit.next();
    setState(() {
      _adding = false;
      _tab = 0;
    });
    context.read<CurrentProblemsCubit>().load();
  }

  @override
  void onHardwareScan(ScanCode code) => onScan(code.raw);

  //* --- скан --- *//

  /// Единая точка для поля и интента сканера. На форме «не нашей марки» скан — это марка.
  Future<void> onScan(String value) async {
    final code = value.trim();
    _scanController.clear();
    // Скан со списка — кладовщик начал фиксировать: открываем форму.
    if (!_adding) setState(() => _adding = true);
    final s = cubit.state;
    if (code.isEmpty || !_deduper.allow(code) || s.outcome != null) return;
    if (s.subject != null) {
      if (s.reason == ProblemReason.foreignMark) _mark.text = code;
      return;
    }
    switch (classifyScan(code)) {
      case ScanKind.cargoUnit:
        await onBoxScan(loadUnitIdFrom(code)!);
      case ScanKind.cell:
        await onCellScan(code);
      case ScanKind.good:
      // Марки и короба «Честного знака» здесь пока не ждут (приёмка марок — CZ-05):
      // как незнакомый код. Раньше код короба (20 цифр) уходил сюда же через «товар».
      case ScanKind.czMark:
      case ScanKind.czBox:
      case ScanKind.unknown:
        snack(t.problems.scanBoxOrCell);
    }
    refocusScan();
  }

  /// Скан QR короба: карточка — с сервера или из снимка со своей очередью поверх.
  Future<void> onBoxScan(String id) async {
    final res = await contents.loadUnit(id);
    if (!mounted) return;
    if (res.isLeft) {
      snack(t.movement.noData);
      return;
    }
    final box = res.right.value;
    if (box == null) {
      cubit.boxNotFound(offline: res.right.freshness is FromSnapshot);
      return;
    }
    await onBox(box);
  }

  /// Короб найден — сканом или в ячейке.
  Future<void> onBox(LoadUnitView box) async {
    final cellId = box.cellId;
    final cell = cellId == null ? null : await cellWhere((c) => c.id == cellId);
    if (mounted) cubit.onBox(box, cell);
  }

  /// Скан этикетки ячейки: адрес ищется в справочнике.
  Future<void> onCellScan(String address) async {
    final a = address.toLowerCase();
    final cell = await cellWhere((c) => c.address.toLowerCase() == a);
    if (!mounted) return;
    if (cell == null) {
      snack(t.movement.cellNotFound(address: address));
      return;
    }
    await onCell(cell);
  }

  /// Ячейка выбрана — сканом или из справочника: её короба и россыпь на выбор.
  Future<void> onCell(Cell cell) async {
    final res = await contents.cell(
      CellRef(id: cell.id, address: cell.address),
    );
    if (!mounted) return;
    final view = res.isRight ? res.right.value : null;
    if (view == null) {
      snack(t.movement.noData);
      return;
    }
    cubit.onCell(cell, view);
  }

  /// Выбрать ячейку вручную — ярлык короба испорчен: его найдут среди коробов ячейки.
  Future<void> chooseCell() async {
    final cell = await showModalBottomSheet<Cell>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.95,
      ),
      builder: (_) => const CellChangeSheet(),
    );
    await hideKeyboard();
    if (cell != null && mounted) await onCell(cell);
    refocusScan();
  }

  /// Ячейка справочника терминала по условию; `null` — такой нет.
  Future<Cell?> cellWhere(bool Function(Cell) test) async {
    final res = await getIt<CatalogRepository>().listAllCells();
    return res
        .fold((_) => const <Cell>[], (cells) => cells)
        .where(test)
        .firstOrNull;
  }

  //* --- что помечаем --- *//

  /// Товар из источника: сколько пометить — по умолчанию всё, что есть. Над полем — что
  /// помечают и сколько лежит, той же шапкой, что в перемещении.
  Future<void> chooseGoods(ContentLine line) async {
    final from = switch (cubit.state.source) {
      SourceBox(:final box, :final cell) => MovePlace(
        cellId: cell.id,
        cellAddress: cell.address,
        loadUnitId: box.id,
      ),
      SourceCell(:final cell) => MovePlace(
        cellId: cell.id,
        cellAddress: cell.address,
      ),
      null => null,
    };
    if (from == null) return;
    final qty = await showQtyDialog(
      context,
      max: line.qty,
      uom: line.uom ?? '',
      title: t.problems.qtyTitle,
      header: MoveQtyHeader(line: line, available: line.qty, from: from),
    );
    if (qty != null && mounted) cubit.chooseGoods(line, qty);
  }

  //* --- навигация и итог --- *//

  /// Назад: в форме — шаг назад, с пустой формы — к списку; со списков — в меню.
  void goBack() {
    if (!_adding) {
      context.router.maybePop();
      return;
    }
    final s = cubit.state;
    if (s.outcome == null && (s.source != null || s.subject != null)) {
      cubit.back();
      refocusScan();
      return;
    }
    finishAdding();
  }

  /// Следующая проблема — поля формы очищаются.
  void next() {
    _comment.clear();
    _mark.clear();
    cubit.next();
    refocusScan();
  }

  /// Подсказка по результату скана — один раз.
  void onNotice(BuildContext context, ProblemState state) {
    final n = state.notice;
    if (n == null) return;
    snack(switch (n) {
      ProblemNoticeReceivingCell() => t.movement.noticeReceivingCell,
      ProblemNoticeBoxEmpty() => t.movement.noticeBoxEmpty,
      ProblemNoticeCellEmpty() => t.problems.cellEmpty,
      ProblemNoticeLabelInvalid() => t.movement.noticeLabelInvalid,
      ProblemNoticeBoxUnknownOffline() => t.movement.noticeBoxUnknownOffline,
    });
    cubit.clearNotice();
  }

  void snack(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<ProblemCubit, ProblemState>(
      listenWhen: (a, b) => b.notice != null && a.notice != b.notice,
      listener: onNotice,
      builder: (context, state) => SystemUiWrapper(
        style: StatusBarStyle.light,
        child: Scaffold(
          resizeToAvoidBottomInset: true,
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
              title: t.problems.title,
              goBack: goBack,
              trailing: !_adding && _tab == 1
                  ? const ResolvedFilterButton()
                  : null,
            ),
          ),
          body: SafeArea(top: false, child: _tabs(state)),
        ),
      ),
    );
  }

  /// Вкладки «Текущие» / «Завершённые». Фиксация и её итог — во весь экран, без вкладок.
  Widget _tabs(ProblemState state) {
    if (_adding) return _body(state);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: AppInsets.h8 + AppInsets.top16,
          child: TabSwitch(
            labels: [t.problems.tabCurrent, t.problems.tabCompleted],
            selected: _tab,
            onSelected: selectTab,
            activeColor: AppColors.kTileProblems,
          ),
        ),
        Expanded(
          child: IndexedStack(
            index: _tab,
            children: [
              CurrentProblemsView(onAdd: startAdding),
              const ResolvedFeed(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _body(ProblemState state) {
    final outcome = state.outcome;
    if (outcome != null) {
      return ProblemOutcomeView(
        outcome: outcome,
        reason: state.rejectReason,
        onNext: next,
        onDone: finishAdding,
      );
    }
    final subject = state.subject;
    if (subject != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppBoxes.kHeight16,
          Expanded(
            child: ProblemForm(
              state: state,
              targets: cubit.targetsFor(subject),
              comment: _comment,
              mark: _mark,
              onWarehouse: cubit.setWarehouse,
              onReason: cubit.setReason,
            ),
          ),
          Padding(
            padding: AppInsets.all16,
            child: FilledButton(
              onPressed: state.canSubmit ? cubit.submit : null,
              child: state.busy
                  ? const SizedBox.square(
                      dimension: AppSizes.kIcon18,
                      child: CircularProgressIndicator(
                        strokeWidth: AppSizes.kIcon2,
                      ),
                    )
                  : Text(t.problems.submit),
            ),
          ),
        ],
      );
    }
    final source = state.source;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: AppInsets.h8 + AppInsets.v16,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ScanField(
                controller: _scanController,
                focusNode: _scanFocus,
                hint: t.problems.scanHint,
                onSubmitted: onScan,
              ),
              AppBoxes.kHeight8,
              NeumorphicActionStack(
                buttons: [
                  NeumorphicActionButton(
                    label: t.movement.chooseCell,
                    icon: MdiIcons.viewGridOutline,
                    onPressed: chooseCell,
                  ),
                ],
              ),
            ],
          ),
        ),
        if (source != null)
          Expanded(
            child: ProblemChoice(
              source: source,
              onWholeBox: cubit.chooseWholeBox,
              onBox: onBox,
              onGoods: chooseGoods,
            ),
          )
        else
          Padding(
            padding: AppInsets.h8,
            child: Text(
              t.problems.emptyHint,
              style: RegularTextStyles().regularInter12.copyWith(
                color: AppColors.kTextMuted,
              ),
            ),
          ),
      ],
    );
  }
}
