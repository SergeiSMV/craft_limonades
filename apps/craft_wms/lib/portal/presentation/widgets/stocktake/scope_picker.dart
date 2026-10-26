import 'dart:async';

import 'package:either_dart/either.dart';
import 'package:flutter/material.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/error/failure.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/utils/search_text.dart';
import '../../../data/stocktakes_repository.dart';
import '../common/portal_filter_chip.dart';
import '../common/portal_search_box.dart';

/// Выбор объектов области пересчёта (P10-05): поле поиска и список под ним — пункты в стиле
/// фильтр-чипов, выбранные вдавлены; выбрать можно несколько. Тот же приём, что у выбора
/// поставщика возврата.
///
/// [serverSearch] — искать на сервере по каждому запросу (ячейки, товары: их тысячи); иначе
/// список грузится один раз и фильтруется здесь (группы, поставщики). У групп отступ — глубина
/// в дереве: матрица — узел дерева, берётся с поддеревом.
class ScopePicker extends StatefulWidget {
  const ScopePicker({
    super.key,
    required this.load,
    required this.hint,
    required this.selected,
    required this.onToggle,
    this.serverSearch = false,
  });

  final Future<Either<Failure, List<ScopeObject>>> Function(String query) load;
  final String hint;

  /// Выбранные: id → подпись.
  final Map<String, String> selected;
  final ValueChanged<ScopeObject> onToggle;
  final bool serverSearch;

  @override
  State<ScopePicker> createState() => _ScopePickerState();
}

class _ScopePickerState extends State<ScopePicker> {
  /// Пауза после ввода перед поиском на сервере — как у поиска номенклатуры.
  static const _debounceDelay = Duration(milliseconds: 350);

  List<ScopeObject> _items = const [];
  bool _loading = true;
  String _query = '';
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _fetch('');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _fetch(String query) async {
    setState(() => _loading = true);
    final res = await widget.load(query);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _items = res.isRight ? res.right : const [];
    });
  }

  /// Запрос поиска изменился: на сервере — с паузой после ввода, иначе — фильтр списка.
  void onQuery(String q) {
    setState(() => _query = q);
    if (!widget.serverSearch) return;
    _debounce?.cancel();
    _debounce = Timer(_debounceDelay, () => _fetch(q));
  }

  @override
  Widget build(BuildContext context) {
    final muted = RegularTextStyles().regularInter14.copyWith(
      color: AppColors.kTextMuted,
    );
    final words = searchWords(_query);
    final shown = widget.serverSearch
        ? _items
        : [
            for (final o in _items)
              if (words.every(normalizeSearchText(o.label).contains)) o,
          ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        PortalSearchBox(hint: widget.hint, onChanged: onQuery),
        AppBoxes.kHeight8,
        Text(
          t.portal.stocktake.picked(count: widget.selected.length),
          style: muted,
        ),
        if (widget.selected.isNotEmpty) ...[
          AppBoxes.kHeight4,
          Wrap(
            spacing: AppSizes.kChipSpacing,
            runSpacing: AppSizes.kChipSpacing,
            children: [
              for (final e in widget.selected.entries)
                PortalFilterChip(
                  label: e.value,
                  selected: true,
                  onTap: () =>
                      widget.onToggle((id: e.key, label: e.value, depth: 0)),
                ),
            ],
          ),
        ],
        AppBoxes.kHeight8,
        ConstrainedBox(
          constraints: const BoxConstraints(
            maxHeight: AppSizes.kPortalPickListMaxHeight,
          ),
          child: _loading
              ? Text(t.portal.stocktake.loading, style: muted)
              : shown.isEmpty
              ? Text(t.portal.stocktake.nothingFound, style: muted)
              : ListView.separated(
                  shrinkWrap: true,
                  itemCount: shown.length,
                  separatorBuilder: (_, _) => AppBoxes.kHeight4,
                  itemBuilder: (_, i) => Padding(
                    padding: EdgeInsets.only(
                      left: AppSizes.kPortalTreeIndent * shown[i].depth,
                    ),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: PortalFilterChip(
                        label: shown[i].label,
                        selected: widget.selected.containsKey(shown[i].id),
                        onTap: () => widget.onToggle(shown[i]),
                      ),
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}
