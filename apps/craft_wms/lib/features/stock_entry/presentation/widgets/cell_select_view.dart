import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/scanner/hardware_scan_listener.dart';
import '../../../../core/scanner/scan_code.dart';
import '../../../../core/scanner/scan_deduper.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../stock/data/catalog_models.dart';
import '../../../stock/data/catalog_repository.dart';
import '../bloc/stock_entry_cubit.dart';
import 'cell_search_field.dart';
import 'committed_cell_tile.dart';

/// Выбор ячейки: поле скана/ввода адреса с инлайн-автокомплитом (локальная фильтрация по загруженному
/// справочнику ячеек) + список пройденных ячеек (тап — редактировать) + кнопка «Завершить ввод».
/// Все данные локальны до финала (вариант A).
class CellSelectView extends StatefulWidget {
  const CellSelectView({super.key, required this.committed});

  final List<CommittedCell> committed;

  @override
  State<CellSelectView> createState() => _CellSelectViewState();
}

class _CellSelectViewState extends State<CellSelectView>
    with HardwareScanListener {
  final _repo = getIt<CatalogRepository>();

  /// Отсекает дубль, если устройство отдаёт код и в поле, и интентом.
  final _deduper = ScanDeduper();

  /// Справочник ячеек склада, загруженный целиком (для мгновенного локального автокомплита).
  List<Cell> _allCells = const [];
  bool _loadingCells = true;

  @override
  void initState() {
    super.initState();
    _loadCells();
  }

  StockEntryCubit get _cubit => context.read<StockEntryCubit>();

  /// Загрузить все ячейки склада разом (пилот — один склад). При ошибке справочник останется пустым,
  /// а резолв адреса упадёт на серверный фоллбэк в [_submitAddress].
  Future<void> _loadCells() async {
    final res = await _repo.listAllCells();
    if (!mounted) return;
    setState(() {
      _loadingCells = false;
      _allCells = res.fold((_) => const [], (cells) => cells);
    });
    if (res.isLeft) _snack(t.stockEntry.cellsLoadFailed);
  }

  /// Точное совпадение адреса (регистронезависимо) среди списка; null — не нашли.
  Cell? _matchExact(Iterable<Cell> cells, String address) {
    final a = address.toLowerCase();
    for (final c in cells) {
      if (c.address.toLowerCase() == a) return c;
    }
    return null;
  }

  /// Код с аппаратного сканера (intent-режим) — тот же путь, что у ввода в поле.
  @override
  void onHardwareScan(ScanCode code) => _submitAddress(code.raw);

  /// Резолв ячейки по введённому/сканированному адресу (точное совпадение). Основной путь — локально
  /// по загруженному справочнику; если он пуст (загрузка не удалась/не завершилась) — серверный фоллбэк,
  /// чтобы скан работал даже без справочника.
  ///
  /// Классификация подключается только после неудачного резолва: справочник — источник истины, и
  /// реальный адрес ячейки должен сработать, даже если его форма ни на что не похожа. Зато когда
  /// ячейка не нашлась, а код опознан как штрихкод товара, сообщение говорит суть, а не «не найдена».
  ///
  /// Единая точка для обоих источников кода, поэтому отсечение дубля стоит здесь: если бы оно
  /// сидело только на ветке потока, пара «поле + интент» прошла бы мимо него.
  Future<void> _submitAddress(String value) async {
    final address = value.trim();
    if (address.isEmpty || !_deduper.allow(address)) return;
    Cell? cell = _matchExact(_allCells, address);
    if (cell == null && _allCells.isEmpty) {
      final res = await _repo.listCells(query: address);
      if (!mounted) return;
      cell = res.fold<Cell?>(
        (_) => null,
        (page) => _matchExact(page.items, address),
      );
    }
    if (cell == null) {
      final kind = classifyScan(address);
      _snack(
        kind == ScanKind.good
            ? t.stockEntry.scannedGoodInCell
            : t.stockEntry.cellNotFound,
      );
      return;
    }
    _cubit.selectCell(cell);
  }

  /// Меню по долгому нажатию на пройденную ячейку: редактировать / удалить.
  Future<void> _showCellMenu(CommittedCell entry) async {
    final action = await showModalBottomSheet<String>(
      backgroundColor: AppColors.kNeumorphicBg,
      context: context,
      builder: (_) => SafeArea(
        child: Padding(
          padding: AppInsets.all16,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              NeumorphicButton(
                onPressed: () => Navigator.of(context).pop('edit'),
                style: NeumorphicStyle(
                  shadowLightColor: AppColors.kNeumorphicLight,
                  shadowDarkColor: AppColors.kNeumorphicDark,
                  intensity: 1,
                  color: AppColors.kNeumorphicBg,
                  depth: 3,
                  shape: NeumorphicShape.flat,
                ),
                child: ListTile(
                  leading: const Icon(Icons.edit_outlined),
                  title: Text(t.stockEntry.edit),
                ),
              ),
              AppBoxes.kHeight8,
              NeumorphicButton(
                onPressed: () => Navigator.of(context).pop('delete'),
                style: NeumorphicStyle(
                  shadowLightColor: AppColors.kNeumorphicLight,
                  shadowDarkColor: AppColors.kNeumorphicDark,
                  intensity: 1,
                  color: AppColors.kNeumorphicBg,
                  depth: 3,
                  shape: NeumorphicShape.flat,
                ),
                child: ListTile(
                  leading: const Icon(
                    Icons.delete_outline,
                    color: AppColors.kDanger,
                  ),
                  title: Text(
                    t.stockEntry.delete,
                    style: const TextStyle(color: AppColors.kDanger),
                  ),
                ),
              ),
            ],
          ),
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

  /// Показать снекбар с текстом (напр. «Ячейка не найдена»).
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
          AppBoxes.kHeight16,
          Padding(
            padding: AppInsets.left12,
            child: Text(
              t.stockEntry.cellPrompt,
              style: RegularTextStyles().regularInter14.copyWith(
                color: AppColors.kTextMuted,
              ),
            ),
          ),
          AppBoxes.kHeight8,

          /// Поле ввода/скана адреса с автокомплитом по локальному справочнику ячеек.
          /// При точном совпадении
          CellSearchField(
            cells: _allCells,
            loading: _loadingCells,
            onPicked: _cubit.selectCell,
            onSubmit: _submitAddress,
          ),

          /// Заголовок секции пройденных ячеек — только если хоть одна уже закрыта.
          if (committed.isNotEmpty) ...[
            AppBoxes.kHeight16,
            Text(
              t.stockEntry.committedTitle(count: committed.length),
              style: RegularTextStyles().regularInter14.copyWith(
                color: AppColors.kTextMuted,
              ),
            ),
            AppBoxes.kHeight8,
          ],

          /// Список пройденных ячеек: занимает всё оставшееся место под полем/заголовком.
          Expanded(
            child: ListView.builder(
              padding: EdgeInsets.zero,
              itemCount: committed.length,
              // Свежая пройденная ячейка — сверху.
              itemBuilder: (context, i) {
                final entry = committed[committed.length - 1 - i];
                return CommittedCellTile(
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
