import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import '../../../core/constants/app_borders.dart';
import '../../../core/constants/app_boxes.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_insets.dart';
import '../../../core/constants/app_sizes.dart';
import '../../../core/di/injection.dart';
import '../../../core/error/failure.dart';
import '../../../core/gen/assets.gen.dart';
import '../../../core/gen/strings.g.dart';
import '../../../core/theme/regular_text.dart';
import '../../../core/theme/semibold_text.dart';
import '../../../core/widgets/system_ui_wrapper.dart';
import '../../stock/data/catalog_models.dart';
import '../../stock/data/catalog_repository.dart';
import 'date_input.dart';
import 'stock_entry_cubit.dart';

/// Экран-поток ввода стартовых остатков (P-FastStart, ТСД). Один экран со стейт-машиной:
/// выбор ячейки → буфер строк ячейки → завершение ячейки → следующая ячейка → завершение ввода.
@RoutePage()
class StockEntryScreen extends StatelessWidget {
  const StockEntryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => getIt<StockEntryCubit>(),
      child: const _StockEntryView(),
    );
  }
}

class _StockEntryView extends StatelessWidget {
  const _StockEntryView();

  /// Текст ошибки для снекбара.
  String _failureText(Failure f) => switch (f) {
    ServerFailure(:final message, :final statusCode) =>
      message ?? 'HTTP $statusCode',
    NetworkFailure() => t.stockEntry.errorNetwork,
    AuthFailure() => t.stockEntry.errorAuth,
    _ => t.stockEntry.errorUnknown,
  };

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
                  t.stockEntry.error(message: _failureText(state.failure!)),
                ),
              ),
            );
          context.read<StockEntryCubit>().clearFailure();
        },
        child: Scaffold(
          appBar: AppBar(
            automaticallyImplyLeading: false,
            title: InkWell(
              onTap: () => context.router.maybePop(),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: AppInsets.right16,
                    child: Assets.icons.arrowLeft.svg(height: AppSizes.kIcon20),
                  ),
                  Flexible(
                    child: Text(
                      t.stockEntry.title,
                      overflow: TextOverflow.ellipsis,
                      style: SemiboldTextStyles().semiboldInter24,
                    ),
                  ),
                ],
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
      return _FinishedView(written: state.written);
    }
    if (state.cell == null) {
      return _CellSelectView(committed: state.committedCells);
    }
    return _CellEntryView(state: state);
  }
}

/// Плитка пройденной ячейки: адрес + число позиций; тап → редактировать, долгое нажатие → меню.
class _CommittedCellTile extends StatelessWidget {
  const _CommittedCellTile({required this.entry, required this.onTap, required this.onLongPress});

  final CommittedCell entry;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: AppInsets.bottom4,
      decoration: BoxDecoration(
        borderRadius: AppBorders.kCircular8,
        color: AppColors.kStockItemBg,
        border: Border(bottom: BorderSide(color: AppColors.kStockItemBorder)),
      ),
      child: ListTile(
        leading: const Icon(Icons.inventory_2_outlined),
        title: Text(entry.cell.address, style: SemiboldTextStyles().semiboldInter16),
        subtitle: Text(
          t.stockEntry.cellPositions(count: entry.lines.length),
          style: RegularTextStyles().regularInter12.copyWith(color: AppColors.kTextMuted),
        ),
        trailing: const Icon(Icons.chevron_right, color: AppColors.kTextMuted),
        onTap: onTap,
        onLongPress: onLongPress,
      ),
    );
  }
}

/// Выбор ячейки: поле скана/ввода адреса + список пройденных ячеек (тап — редактировать) + кнопка
/// «Завершить ввод». Все данные локальны до финала (вариант A).
class _CellSelectView extends StatefulWidget {
  const _CellSelectView({required this.committed});

  final List<CommittedCell> committed;

  @override
  State<_CellSelectView> createState() => _CellSelectViewState();
}

class _CellSelectViewState extends State<_CellSelectView> {
  final _controller = TextEditingController();
  final _repo = getIt<CatalogRepository>();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  StockEntryCubit get _cubit => context.read<StockEntryCubit>();

  /// Резолв ячейки по введённому/сканированному адресу (точное совпадение).
  Future<void> _submitAddress(String value) async {
    final address = value.trim();
    if (address.isEmpty) return;
    final res = await _repo.listCells(query: address);
    if (!mounted) return;
    final cell = res.fold<Cell?>((_) => null, (page) {
      for (final c in page.items) {
        if (c.address.toLowerCase() == address.toLowerCase()) return c;
      }
      return null;
    });
    if (cell == null) {
      _snack(t.stockEntry.cellNotFound);
      return;
    }
    _controller.clear();
    _cubit.selectCell(cell);
  }

  /// Выбор ячейки из списка (поиск по адресу).
  Future<void> _pickFromList() async {
    final cell = await showModalBottomSheet<Cell>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _CellPickerSheet(repo: _repo),
    );
    if (cell != null && mounted) _cubit.selectCell(cell);
  }

  /// Меню по долгому нажатию на пройденную ячейку: редактировать / удалить.
  Future<void> _showCellMenu(CommittedCell entry) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: Text(t.stockEntry.edit),
              onTap: () => Navigator.of(context).pop('edit'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: AppColors.kDanger),
              title: Text(t.stockEntry.deleteCell, style: const TextStyle(color: AppColors.kDanger)),
              onTap: () => Navigator.of(context).pop('delete'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'edit') {
      _cubit.selectCell(entry.cell);
    } else if (action == 'delete') {
      _cubit.removeCommittedCell(entry.cell.id);
    }
  }

  void _snack(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final committed = widget.committed;
    return Padding(
      padding: AppInsets.h8,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            t.stockEntry.cellPrompt,
            style: RegularTextStyles().regularInter14.copyWith(color: AppColors.kTextMuted),
          ),
          AppBoxes.kHeight4,
          TextField(
            controller: _controller,
            autofocus: true,
            textInputAction: TextInputAction.done,
            onSubmitted: _submitAddress,
            decoration: InputDecoration(
              prefixIcon: Icon(MdiIcons.qrcode, size: AppSizes.kIcon25, color: AppColors.kSidebarHover),
              suffixIcon: InkWell(
                onTap: _pickFromList,
                child: Icon(MdiIcons.formatListBulleted, size: AppSizes.kIcon25, color: AppColors.kSidebarHover),
              ),
              hintText: t.stockEntry.cellHint,
              border: const OutlineInputBorder(borderRadius: AppBorders.kCircular8),
              isDense: true,
            ),
          ),
          if (committed.isNotEmpty) ...[
            AppBoxes.kHeight16,
            Text(
              t.stockEntry.committedTitle(count: committed.length),
              style: RegularTextStyles().regularInter14.copyWith(color: AppColors.kTextMuted),
            ),
            AppBoxes.kHeight8,
          ],
          Expanded(
            child: ListView.builder(
              padding: EdgeInsets.zero,
              itemCount: committed.length,
              // Свежая пройденная ячейка — сверху.
              itemBuilder: (context, i) {
                final entry = committed[committed.length - 1 - i];
                return _CommittedCellTile(
                  entry: entry,
                  onTap: () => _cubit.selectCell(entry.cell),
                  onLongPress: () => _showCellMenu(entry),
                );
              },
            ),
          ),
          if (committed.isNotEmpty)
            SafeArea(
              top: false,
              child: Padding(
                padding: AppInsets.v16,
                child: FilledButton(
                  onPressed: () => _cubit.finishSession(),
                  child: Text(t.stockEntry.finishSession),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Работа с выбранной ячейкой: шапка + поле скана товара + список строк буфера + действия.
class _CellEntryView extends StatefulWidget {
  const _CellEntryView({required this.state});

  final StockEntryState state;

  @override
  State<_CellEntryView> createState() => _CellEntryViewState();
}

class _CellEntryViewState extends State<_CellEntryView> {
  final _scanController = TextEditingController();
  final _scanFocus = FocusNode();
  final _repo = getIt<CatalogRepository>();

  @override
  void dispose() {
    _scanController.dispose();
    _scanFocus.dispose();
    super.dispose();
  }

  StockEntryCubit get _cubit => context.read<StockEntryCubit>();

  /// Вернуть фокус скан-полю (после диалогов) — иначе сканер DT50 печатает «в никуда».
  void _refocusScan() {
    if (mounted) _scanFocus.requestFocus();
  }

  /// Скан ШК товара. Порядок резолва: копилка привязок прохода → сервер → ручная привязка. Локальный
  /// шаг нужен, чтобы повторный скан любого уже привязанного за проход ШК узнавался сразу, а не бил в
  /// 404 (данные ещё не на сервере) — сколько бы ШК ни было на товар. По завершении — возврат фокуса.
  Future<void> _onScan(String value) async {
    final code = value.trim();
    _scanController.clear();
    if (code.isNotEmpty) {
      final local = _cubit.localGoodForBarcode(code);
      if (local != null) {
        await _collectAndAdd(local); // уже привязан за проход — просто строка, без повторной привязки
      } else {
        final good = await _cubit.resolveBarcode(code);
        if (!mounted) return;
        if (good != null) {
          await _collectAndAdd(good); // есть в БД
        } else {
          _snack(t.stockEntry.goodNotBound);
          final picked = await _pickGood();
          if (picked != null && mounted) {
            await _collectAndAdd(picked, newBarcode: code); // новый ШК → в копилку прохода
          }
        }
      }
    }
    _refocusScan();
  }

  /// Ручное добавление товара (без ШК).
  Future<void> _addManual() async {
    final picked = await _pickGood();
    if (picked != null && mounted) await _collectAndAdd(picked);
    _refocusScan();
  }

  /// Спросить дату + количество и добавить строку в буфер. [newBarcode] — новый ШК для привязки
  /// к товару (кладётся в копилку прохода вместе с добавлением строки).
  Future<void> _collectAndAdd(Good good, {String? newBarcode}) async {
    final res = await _showDateQty(good);
    if (res == null || !mounted) return;
    _cubit.addLine(
      good: good,
      date: res.date,
      qty: res.qty,
      newBarcode: newBarcode,
      symbology: newBarcode != null ? '' : null,
    );
  }

  /// Меню по долгому нажатию на строку: редактировать / удалить.
  Future<void> _showLineMenu(EntryLineDraft line) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: Text(t.stockEntry.edit),
              onTap: () => Navigator.of(context).pop('edit'),
            ),
            ListTile(
              leading: const Icon(
                Icons.delete_outline,
                color: AppColors.kDanger,
              ),
              title: Text(
                t.stockEntry.delete,
                style: const TextStyle(color: AppColors.kDanger),
              ),
              onTap: () => Navigator.of(context).pop('delete'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'delete') {
      _cubit.removeLine(line);
    } else if (action == 'edit') {
      await _editLine(line);
    }
  }

  /// Редактирование строки: диалог с текущими датой и количеством.
  Future<void> _editLine(EntryLineDraft line) async {
    final res = await showDialog<_DateQty>(
      context: context,
      builder: (_) => _DateQtyDialog(
        good: line.good,
        initialDate: line.productionDate,
        initialQty: line.qty,
      ),
    );
    if (res == null || !mounted) return;
    _cubit.editLine(line, date: res.date, qty: res.qty);
  }

  Future<Good?> _pickGood() => showModalBottomSheet<Good>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _GoodPickerSheet(repo: _repo),
  );

  Future<_DateQty?> _showDateQty(Good good) => showDialog<_DateQty>(
    context: context,
    builder: (_) => _DateQtyDialog(good: good),
  );

  void _snack(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final cell = state.cell!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Шапка ячейки.
        Container(
          color: AppColors.kStockItemBg,
          padding: AppInsets.v8 + AppInsets.h14,
          child: Row(
            children: [
              const Icon(
                Icons.inventory_2_outlined,
                size: AppSizes.kIcon20,
                color: AppColors.kSidebarHover,
              ),
              AppBoxes.kWidth8,
              Expanded(
                child: Text(
                  t.stockEntry.currentCell(address: cell.address),
                  style: SemiboldTextStyles().semiboldInter14.copyWith(
                    color: AppColors.kSidebarHover,
                  ),
                ),
              ),
              if (state.undoStack.isNotEmpty)
                TextButton.icon(
                  onPressed: _cubit.undo,
                  icon: const Icon(Icons.undo, size: AppSizes.kIcon18),
                  label: Text(t.stockEntry.undo),
                ),
            ],
          ),
        ),
        TextField(
          cursorColor: AppColors.kPrimary,
          cursorWidth: 1,
          cursorHeight: 14,
          controller: _scanController,
          focusNode: _scanFocus,
          autofocus: true,
          // Ввод только сканером (аппаратная «клавиатура» DT50) — софт-клавиатуру не показываем,
          // чтобы после «Добавить»/скана она не всплывала. Ручной выбор товара — кнопкой ниже.
          keyboardType: TextInputType.none,
          textInputAction: TextInputAction.done,
          onSubmitted: _onScan,
          decoration: InputDecoration(
            filled: true,
            fillColor: AppColors.kPrimary,
            focusedBorder: const OutlineInputBorder(
              borderSide: BorderSide(color: AppColors.kPrimary),
            ),
            prefixIcon: const Icon(
              Icons.qr_code_scanner,
              size: AppSizes.kIcon20,
              color: AppColors.kBadgeSuccessBg,
            ),
            hintText: t.stockEntry.scanGood,
            hintStyle: RegularTextStyles().regularInter14.copyWith(
              color: AppColors.kBadgeSuccessBg,
            ),
            suffixIcon: InkWell(
              onTap: _addManual,
              child: Icon(
                MdiIcons.formatListBulleted,
                size: AppSizes.kIcon25,
                color: AppColors.kSidebarHover,
              ),
            ),
            isDense: true,
          ),
        ),

        /// TODO: кнопка «Добавить вручную» — пока не нужна, т.к. есть сканер и выбор из списка
        // Padding(
        //   padding: AppInsets.h16 + AppInsets.top8,
        //   child: Align(
        //     alignment: Alignment.centerLeft,
        //     child: TextButton.icon(
        //       onPressed: _addManual,
        //       icon: const Icon(Icons.add, size: AppSizes.kIcon18),
        //       label: Text(t.stockEntry.addManual),
        //     ),
        //   ),
        // ),
        Expanded(
          child: state.lines.isEmpty
              ? Center(
                  child: Text(
                    t.stockEntry.emptyBuffer,
                    style: RegularTextStyles().regularInter14.copyWith(
                      color: AppColors.kTextMuted,
                    ),
                  ),
                )
              : ListView.builder(
                  padding: AppInsets.h8 + AppInsets.top8,
                  itemCount: state.lines.length,
                  // От последнего добавленного: свежая строка — сверху.
                  itemBuilder: (context, i) {
                    final line = state.lines[state.lines.length - 1 - i];
                    return _LineTile(
                      line: line,
                      onLongPress: () => _showLineMenu(line),
                    );
                  },
                ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: AppInsets.all16,
            child: FilledButton.icon(
              onPressed: state.lines.isEmpty ? null : _cubit.finishCell,
              icon: const Icon(Icons.check),
              label: Text(t.stockEntry.finishCell),
            ),
          ),
        ),
      ],
    );
  }
}

/// Строка буфера: товар · партия · количество (с единицей). ШК на строке не хранится — привязки
/// живут отдельно (уровень товара), поэтому и метки ШК на строке нет.
class _LineTile extends StatelessWidget {
  const _LineTile({required this.line, this.onLongPress});

  final EntryLineDraft line;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: AppInsets.bottom4,
      decoration: BoxDecoration(
        borderRadius: AppBorders.kCircular8,
        color: AppColors.kStockItemBg,
        border: Border(bottom: BorderSide(color: AppColors.kStockItemBorder)),
      ),
      child: ListTile(
        onLongPress: onLongPress,
        title: Text(line.good.name, style: RegularTextStyles().regularInter14),
        subtitle: Text(
          t.stockEntry.lineSubtitle(date: line.productionDate),
          style: RegularTextStyles().regularInter10.copyWith(
            color: AppColors.kTextMuted,
          ),
        ),
        trailing: Text(
          t.stockEntry.qtyWithUom(
            qty: _fmtQty(line.qty),
            uom: line.good.uom,
          ),
          style: SemiboldTextStyles().semiboldInter16,
        ),
      ),
    );
  }
}

/// Итог ввода: сколько строк записано, куда смотреть, кнопка на главную.
class _FinishedView extends StatelessWidget {
  const _FinishedView({required this.written});

  final int written;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: AppInsets.all32,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.check_circle,
              color: AppColors.kBadgeSuccessText,
              size: 64,
            ),
            AppBoxes.kHeight16,
            Text(
              t.stockEntry.finishedTitle,
              style: SemiboldTextStyles().semiboldInter24,
            ),
            AppBoxes.kHeight8,
            Text(
              t.stockEntry.finishedText(written: written),
              textAlign: TextAlign.center,
              style: RegularTextStyles().regularInter14.copyWith(
                color: AppColors.kTextMuted,
              ),
            ),
            AppBoxes.kHeight24,
            FilledButton(
              onPressed: () => context.router.maybePop(),
              child: Text(t.stockEntry.toHome),
            ),
          ],
        ),
      ),
    );
  }
}

/// Диалог ввода даты выпуска (ДД-ММ-ГГГГ) и количества для строки товара.
class _DateQtyDialog extends StatefulWidget {
  const _DateQtyDialog({required this.good, this.initialDate, this.initialQty});

  final Good good;
  final String?
  initialDate; // префилл при редактировании (для нового товара — null)
  final double? initialQty;

  @override
  State<_DateQtyDialog> createState() => _DateQtyDialogState();
}

class _DateQtyDialogState extends State<_DateQtyDialog> {
  late final _date = TextEditingController(text: widget.initialDate ?? '');
  late final _qty = TextEditingController(
    text: widget.initialQty != null ? _fmtQty(widget.initialQty!) : '',
  );
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _date.dispose();
    _qty.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    final qty = double.parse(_qty.text.trim().replaceAll(',', '.'));
    FocusManager.instance.primaryFocus
        ?.unfocus(); // свернуть клавиатуру при подтверждении
    // Год мог быть введён двумя знаками (14.08.26) — приводим к дд.мм.гггг на выходе.
    Navigator.of(context).pop(
      _DateQty(date: normalizeEntryDate(_date.text.trim()), qty: qty),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      // scrollable — чтобы текст ошибки валидации (доп. высота под полем) не переполнял диалог,
      // а прокручивался; особенно при поднятой клавиатуре и малой доступной высоте.
      scrollable: true,
      title: Text(
        widget.good.name,
        style: SemiboldTextStyles().semiboldInter16,
      ),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _date,
              keyboardType: TextInputType.number,
              inputFormatters: [DateTextInputFormatter()],
              decoration: InputDecoration(
                labelText: t.stockEntry.dateLabel,
                hintText: 'дд.мм.гг(гг)',
              ),
              validator: (v) => isValidEntryDate((v ?? '').trim())
                  ? null
                  : t.stockEntry.dateInvalid,
            ),
            AppBoxes.kHeight12,
            TextFormField(
              controller: _qty,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                labelText: t.stockEntry.qtyLabel(uom: widget.good.uom),
              ),
              validator: (v) {
                final d = double.tryParse(
                  (v ?? '').trim().replaceAll(',', '.'),
                );
                return (d != null && d > 0) ? null : t.stockEntry.qtyInvalid;
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.stockEntry.cancel),
        ),
        FilledButton(onPressed: _submit, child: Text(t.stockEntry.add)),
      ],
    );
  }
}

/// Результат диалога даты/количества.
class _DateQty {
  const _DateQty({required this.date, required this.qty});

  final String date;
  final double qty;
}

/// Нижний лист выбора товара из номенклатуры (поиск с дебаунсом).
class _GoodPickerSheet extends StatefulWidget {
  const _GoodPickerSheet({required this.repo});

  final CatalogRepository repo;

  @override
  State<_GoodPickerSheet> createState() => _GoodPickerSheetState();
}

class _GoodPickerSheetState extends State<_GoodPickerSheet> {
  Timer? _debounce;
  List<Good> _goods = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load(null);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _load(String? query) async {
    setState(() => _loading = true);
    final res = await widget.repo.listGoods(query: query, limit: 50);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _goods = res.fold((_) => const [], (p) => p.items);
    });
  }

  void _onSearch(String value) {
    _debounce?.cancel();
    _debounce = Timer(
      const Duration(milliseconds: 350),
      () => _load(value.isEmpty ? null : value),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding:
            AppInsets.all16 +
            EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              t.stockEntry.pickGood,
              style: SemiboldTextStyles().semiboldInter18,
            ),
            AppBoxes.kHeight12,
            TextField(
              autofocus: true,
              onChanged: _onSearch,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: t.stockEntry.searchGood,
                border: const OutlineInputBorder(
                  borderRadius: AppBorders.kCircular8,
                ),
                isDense: true,
              ),
            ),
            AppBoxes.kHeight12,
            Flexible(
              child: _loading
                  ? const Center(
                      child: Padding(
                        padding: AppInsets.all16,
                        child: CircularProgressIndicator(),
                      ),
                    )
                  : _goods.isEmpty
                  ? Center(child: Text(t.stockEntry.nothingFound))
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: _goods.length,
                      itemBuilder: (context, i) {
                        final g = _goods[i];
                        return ListTile(
                          title: Text(
                            g.name,
                            style: RegularTextStyles().regularInter14,
                          ),
                          subtitle: Text(
                            [if (g.code != null) g.code!, g.uom].join(' · '),
                            style: RegularTextStyles().regularInter10.copyWith(
                              color: AppColors.kTextMuted,
                            ),
                          ),
                          onTap: () => Navigator.of(context).pop(g),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Нижний лист выбора ячейки (поиск по адресу).
class _CellPickerSheet extends StatefulWidget {
  const _CellPickerSheet({required this.repo});

  final CatalogRepository repo;

  @override
  State<_CellPickerSheet> createState() => _CellPickerSheetState();
}

class _CellPickerSheetState extends State<_CellPickerSheet> {
  Timer? _debounce;
  List<Cell> _cells = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load(null);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _load(String? query) async {
    setState(() => _loading = true);
    final res = await widget.repo.listCells(query: query, limit: 50);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _cells = res.fold((_) => const [], (p) => p.items);
    });
  }

  void _onSearch(String value) {
    _debounce?.cancel();
    _debounce = Timer(
      const Duration(milliseconds: 350),
      () => _load(value.isEmpty ? null : value),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding:
            AppInsets.all16 +
            EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              t.stockEntry.pickCell,
              style: SemiboldTextStyles().semiboldInter18,
            ),
            AppBoxes.kHeight12,
            TextField(
              autofocus: true,
              onChanged: _onSearch,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: t.stockEntry.cellHint,
                border: const OutlineInputBorder(
                  borderRadius: AppBorders.kCircular8,
                ),
                isDense: true,
              ),
            ),
            AppBoxes.kHeight12,
            Flexible(
              child: _loading
                  ? const Center(
                      child: Padding(
                        padding: AppInsets.all16,
                        child: CircularProgressIndicator(),
                      ),
                    )
                  : _cells.isEmpty
                  ? Center(child: Text(t.stockEntry.nothingFound))
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: _cells.length,
                      itemBuilder: (context, i) {
                        final c = _cells[i];
                        return ListTile(
                          leading: c.isFloor
                              ? const Icon(Icons.south)
                              : const Icon(Icons.grid_view),
                          title: Text(
                            c.address,
                            style: RegularTextStyles().regularInter14,
                          ),
                          onTap: () => Navigator.of(context).pop(c),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Формат количества: целое без дробной части, иначе — с точкой без хвостовых нулей.
String _fmtQty(double q) {
  if (q == q.roundToDouble()) return q.toInt().toString();
  return q.toString();
}
