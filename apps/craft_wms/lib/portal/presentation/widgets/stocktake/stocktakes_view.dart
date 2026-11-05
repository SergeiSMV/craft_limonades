import 'package:flutter/material.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/error/failure.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/sync/data_versions.dart';
import '../../../../core/widgets/data_versions_listener.dart';
import '../../../data/stocktakes_repository.dart';
import '../settings/access_common.dart';
import '../ui/portal_button.dart';
import '../ui/portal_card.dart';
import '../ui/portal_choice.dart';
import '../ui/portal_list_page.dart';
import 'stocktake_card.dart';
import 'stocktake_create_dialog.dart';
import 'stocktake_dialogs.dart';
import 'stocktake_labels.dart';
import '../../../../core/utils/doc_number.dart';

/// Пересчёты в портале (P10-05, плоский стиль — ADHOC-56): открытые и закрытые,
/// «Завести пересчёт», ход и закрытие.
class StocktakesView extends StatefulWidget {
  const StocktakesView({super.key, this.canManage = true, this.header});

  /// Право «Пересчёты: заводить и закрывать» (ADHOC-50); без него — только ход.
  final bool canManage;

  /// Над панелью, закреплён вместе с ней: переключатель видов «Инвентаризации».
  final Widget? header;

  @override
  State<StocktakesView> createState() => _StocktakesViewState();
}

class _StocktakesViewState extends State<StocktakesView> {
  final _repo = getIt<StocktakesRepository>();

  bool _loading = true;
  Failure? _error;
  List<PortalStocktake> _items = const [];
  bool _closedTab = false;
  final _closing = <String>{}; // id пересчётов, которые сейчас закрываются

  /// Номер последнего запроса списка: ответ на более ранний — устарел.
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Загрузить пересчёты выбранного фильтра. [quiet] — перечитывание по версиям данных
  /// (ADHOC-60): список остаётся на экране до ответа, а ошибка не подменяет его. Номер запроса
  /// отбрасывает ответ, устаревший из-за смены фильтра во время чтения.
  Future<void> _load({bool quiet = false}) async {
    final seq = ++_seq;
    if (!quiet) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    final res = await _repo.list(status: _closedTab ? 'closed' : 'open');
    if (!mounted || seq != _seq || (quiet && res.isLeft)) return;
    setState(() {
      _loading = false;
      res.fold((f) => _error = f, (list) {
        _items = list;
        _error = null;
      });
    });
  }

  /// Пересчёты изменились на сервере (ADHOC-60): тихо перечитать под выбранный фильтр.
  void _onDataChanged() => _load(quiet: true);

  /// Открытые / закрытые.
  void _onFilter(bool closed) {
    setState(() => _closedTab = closed);
    _load();
  }

  /// Завести пересчёт: область — в диалоге; после — список перечитывается.
  Future<void> _create() async {
    final created = await showStocktakeCreateDialog(context);
    if (created == null || !mounted) return;
    _snack(
      t.portal.stocktake.createDone(
        number: docNumber(DocKind.stocktake, created.number),
        cells: created.cells,
      ),
    );
    _load();
  }

  /// Закрыть пересчёт — с подтверждением; неподсчитанные ячейки — досрочно (force).
  Future<void> _close(PortalStocktake s) async {
    if (_closing.contains(s.id) ||
        !await showStocktakeCloseDialog(context, s)) {
      return;
    }
    if (!mounted) return;
    setState(() => _closing.add(s.id));
    final res = await _repo.close(s.id, force: s.counted < s.cells);
    if (!mounted) return;
    setState(() => _closing.remove(s.id));
    res.fold(
      (f) => _snack(t.portal.stocktake.error(message: stocktakeErrorText(f))),
      (_) {
        _snack(t.portal.stocktake.closed);
        _load();
      },
    );
  }

  void _snack(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    // Страница-список (ADHOC-56): переключатель видов и панель закреплены, список прокручивается.
    return DataVersionsListener(
      domains: const {DataDomain.stocktakes},
      onChanged: _onDataChanged,
      child: PortalListPage(
        header: widget.header,
        toolbar: Wrap(
          spacing: AppSizes.kChipSpacing,
          runSpacing: AppSizes.kChipSpacing,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            PortalChoice(
              label: t.portal.stocktake.filterOpen,
              selected: !_closedTab,
              onTap: () => _onFilter(false),
            ),
            PortalChoice(
              label: t.portal.stocktake.filterClosed,
              selected: _closedTab,
              onTap: () => _onFilter(true),
            ),
            if (widget.canManage)
              PortalButton(
                label: t.portal.stocktake.create,
                icon: Icons.add,
                kind: PortalButtonKind.primary,
                onPressed: _create,
              ),
          ],
        ),
        body: _list(),
      ),
    );
  }

  /// Пересчёты строками одной карточки; вместо них — загрузка / ошибка / пусто.
  Widget _list() {
    if (_loading) {
      return const SettingsListCard(loading: true, rows: []);
    }
    if (_error case final e?) {
      return PortalCard(
        children: [
          Padding(
            padding: AppInsets.cardRow,
            child: Row(
              children: [
                Expanded(
                  child: AccessError(
                    t.portal.stocktake.error(message: stocktakeErrorText(e)),
                  ),
                ),
                AppBoxes.kWidth8,
                PortalButton(label: t.portal.stocktake.retry, onPressed: _load),
              ],
            ),
          ),
        ],
      );
    }
    if (_items.isEmpty) {
      return PortalCard(
        children: [
          Padding(
            padding: AppInsets.cardRow,
            child: Text(
              t.portal.stocktake.empty,
              style: RegularTextStyles().regularInter13.copyWith(
                color: AppColors.kTextMuted,
              ),
            ),
          ),
        ],
      );
    }
    return PortalCard(
      children: [
        for (final s in _items)
          StocktakeCard(
            stocktake: s,
            busy: _closing.contains(s.id),
            onProgress: () => showStocktakeProgressDialog(context, s),
            onClose: widget.canManage ? () => _close(s) : null,
          ),
      ],
    );
  }
}
