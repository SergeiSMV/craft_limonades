import 'package:flutter/material.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/error/failure.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../data/stocktakes_repository.dart';
import '../common/neumorphic_text_button.dart';
import '../common/portal_filter_chip.dart';
import 'stocktake_card.dart';
import 'stocktake_create_dialog.dart';
import 'stocktake_dialogs.dart';
import 'stocktake_labels.dart';
import '../../../../core/utils/doc_number.dart';

/// Пересчёты в портале (P10-05): открытые и закрытые, «Завести пересчёт», ход и закрытие.
class StocktakesView extends StatefulWidget {
  const StocktakesView({
    super.key,
    required this.padding,
    this.canManage = true,
  });

  /// Право «Пересчёты: заводить и закрывать» (ADHOC-50); без него — только ход.
  final bool canManage;

  final EdgeInsets padding;

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

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Загрузить пересчёты выбранного фильтра.
  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final res = await _repo.list(status: _closedTab ? 'closed' : 'open');
    if (!mounted) return;
    setState(() {
      _loading = false;
      res.fold((f) => _error = f, (list) => _items = list);
    });
  }

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
    final pad = widget.padding;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: pad.copyWith(top: 0, bottom: 0),
          child: Wrap(
            spacing: AppSizes.kChipSpacing,
            runSpacing: AppSizes.kChipSpacing,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (widget.canManage)
                NeumorphicTextButton(
                  label: t.portal.stocktake.create,
                  accent: true,
                  onPressed: _create,
                ),
              PortalFilterChip(
                label: t.portal.stocktake.filterOpen,
                selected: !_closedTab,
                onTap: () => _onFilter(false),
              ),
              PortalFilterChip(
                label: t.portal.stocktake.filterClosed,
                selected: _closedTab,
                onTap: () => _onFilter(true),
              ),
            ],
          ),
        ),
        AppBoxes.kHeight8,
        Expanded(child: _list(pad)),
      ],
    );
  }

  Widget _list(EdgeInsets pad) {
    final muted = RegularTextStyles().regularInter14.copyWith(
      color: AppColors.kTextMuted,
    );
    if (_loading) {
      return const Padding(
        padding: AppInsets.all32,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_error case final e?) {
      return Padding(
        padding: pad,
        child: Column(
          children: [
            Text(
              t.portal.stocktake.error(message: stocktakeErrorText(e)),
              style: muted.copyWith(color: AppColors.kDanger),
            ),
            AppBoxes.kHeight16,
            OutlinedButton(
              onPressed: _load,
              child: Text(t.portal.stocktake.retry),
            ),
          ],
        ),
      );
    }
    if (_items.isEmpty) {
      return Padding(
        padding: pad,
        child: Text(t.portal.stocktake.empty, style: muted),
      );
    }
    return ListView.separated(
      padding: pad.copyWith(top: AppSizes.kDocListGap),
      itemCount: _items.length,
      separatorBuilder: (_, _) => AppBoxes.kHeight16,
      itemBuilder: (_, i) => Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: AppSizes.kDocTableMaxWidth,
          ),
          child: SizedBox(
            width: double.infinity,
            child: StocktakeCard(
              stocktake: _items[i],
              busy: _closing.contains(_items[i].id),
              onProgress: () => showStocktakeProgressDialog(context, _items[i]),
              onClose: widget.canManage ? () => _close(_items[i]) : null,
            ),
          ),
        ),
      ),
    );
  }
}
