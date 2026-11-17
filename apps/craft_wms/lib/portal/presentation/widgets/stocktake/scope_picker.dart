import 'dart:async';

import 'package:either_dart/either.dart';
import 'package:flutter/material.dart';

import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/error/failure.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';
import '../../../../core/utils/search_text.dart';
import '../../../domain/stocktakes/stocktakes_repository.dart';
import '../ui/portal_input.dart';

/// Выбор объектов области пересчёта (P10-05, плоский стиль - ADHOC-56): поле поиска, под ним
/// выбранные отметками с крестиком и список строк с галочками в рамке; выбрать можно
/// несколько.
///
/// [serverSearch] - искать на сервере по каждому запросу (ячейки, товары: их тысячи); иначе
/// список грузится один раз и фильтруется здесь (группы, поставщики). У групп отступ - глубина
/// в дереве: матрица - узел дерева, берётся с поддеревом.
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
  /// Пауза после ввода перед поиском на сервере - как у поиска номенклатуры.
  static const _debounceDelay = Duration(milliseconds: 350);

  List<ScopeObject> _items = const [];
  bool _loading = true;
  String _query = '';
  Timer? _debounce;
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    _fetch('');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
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

  /// Запрос поиска изменился: на сервере - с паузой после ввода, иначе - фильтр списка.
  void onQuery(String q) {
    setState(() => _query = q);
    if (!widget.serverSearch) return;
    _debounce?.cancel();
    _debounce = Timer(_debounceDelay, () => _fetch(q));
  }

  @override
  Widget build(BuildContext context) {
    final muted = RegularTextStyles().regularInter13.copyWith(
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
        PortalInput(
          controller: _search,
          hint: widget.hint,
          icon: Icons.search,
          onChanged: onQuery,
        ),
        AppBoxes.kHeight8,
        Text(
          t.portal.stocktake.picked(count: widget.selected.length),
          style: muted,
        ),
        if (widget.selected.isNotEmpty) ...[
          AppBoxes.kHeight8,
          Wrap(
            spacing: AppSizes.kChipSpacing,
            runSpacing: AppSizes.kChipSpacing,
            children: [
              for (final e in widget.selected.entries)
                _SelectedTag(
                  label: e.value,
                  onRemove: () =>
                      widget.onToggle((id: e.key, label: e.value, depth: 0)),
                ),
            ],
          ),
        ],
        AppBoxes.kHeight8,
        // Список в рамке поля: видно, где он кончается и что прокручивается внутри.
        DecoratedBox(
          decoration: const BoxDecoration(
            borderRadius: AppBorders.kCircular8,
            border: Border.fromBorderSide(
              BorderSide(color: AppColors.kInputBorder),
            ),
          ),
          child: ClipRRect(
            borderRadius: AppBorders.kCircular8,
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxHeight: AppSizes.kPortalPickListMaxHeight,
              ),
              child: _loading || shown.isEmpty
                  ? Padding(
                      padding: AppInsets.cardRow,
                      child: Text(
                        _loading
                            ? t.portal.stocktake.loading
                            : t.portal.stocktake.nothingFound,
                        style: muted,
                      ),
                    )
                  : ListView.separated(
                      shrinkWrap: true,
                      itemCount: shown.length,
                      separatorBuilder: (_, _) => const Divider(
                        height: 1,
                        thickness: 1,
                        color: AppColors.kDivider,
                      ),
                      itemBuilder: (_, i) => _OptionRow(
                        object: shown[i],
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

/// Строка списка выбора: галочка и подпись; у групп - отступ по глубине в дереве.
class _OptionRow extends StatelessWidget {
  const _OptionRow({
    required this.object,
    required this.selected,
    required this.onTap,
  });

  final ScopeObject object;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    hoverColor: AppColors.kBg,
    child: Padding(
      padding: AppInsets.pickRow.copyWith(
        left:
            AppInsets.pickRow.left + AppSizes.kPortalTreeIndent * object.depth,
      ),
      child: Row(
        children: [
          Checkbox(
            value: selected,
            activeColor: AppColors.kButtonPrimary,
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            onChanged: (_) => onTap(),
          ),
          AppBoxes.kWidth4,
          Expanded(
            child: Text(
              object.label,
              style: RegularTextStyles().regularInter13.copyWith(
                color: AppColors.kTextMain,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

/// Выбранный объект - отметка с крестиком: нажатие снимает выбор.
class _SelectedTag extends StatelessWidget {
  const _SelectedTag({required this.label, required this.onRemove});

  final String label;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) => Material(
    color: AppColors.kBadgeNeutralBg,
    borderRadius: AppBorders.kCircular6,
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: onRemove,
      child: Padding(
        padding: AppInsets.tag,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: SemiboldTextStyles().semiboldInter12.copyWith(
                  color: AppColors.kBadgeNeutralText,
                ),
              ),
            ),
            AppBoxes.kWidth4,
            const Icon(
              Icons.close,
              size: AppSizes.kIcon16,
              color: AppColors.kBadgeNeutralText,
            ),
          ],
        ),
      ),
    ),
  );
}
