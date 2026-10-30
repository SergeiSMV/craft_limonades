import 'package:flutter/material.dart';

import '../../../../core/constants/app_sizes.dart';
import '../../../../core/gen/strings.g.dart';
import '../ui/portal_choice.dart';
import '../ui/portal_input.dart';
import 'doc_filter.dart';

/// Панель над таблицей документов (ADHOC-26, плоский стиль — ADHOC-56): поиск и фильтры по
/// состоянию в 1С со счётчиками. Счётчики — по всему списку, без учёта поиска.
///
/// Раскладка — переносом, как панель товаров: в широком окне всё в строку, в узком поиск
/// занимает строку целиком, фильтры уходят под него.
class DocToolbar extends StatefulWidget {
  const DocToolbar({
    super.key,
    required this.hint,
    required this.onQuery,
    required this.filter,
    required this.counts,
    required this.onFilter,
  });

  /// Подсказка в поле поиска — по каким полям ищет форма.
  final String hint;
  final ValueChanged<String> onQuery;
  final DocFilter filter;
  final Map<DocFilter, int> counts;
  final ValueChanged<DocFilter> onFilter;

  @override
  State<DocToolbar> createState() => _DocToolbarState();
}

class _DocToolbarState extends State<DocToolbar> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// Подпись фильтра.
  String _label(DocFilter f) => switch (f) {
    DocFilter.all => t.portal.documents.filterAll,
    DocFilter.waiting => t.portal.documents.filterWaiting,
    DocFilter.posted => t.portal.documents.filterPosted,
  };

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => Wrap(
        spacing: AppSizes.kChipSpacing,
        runSpacing: AppSizes.kChipSpacing,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SizedBox(
            width: constraints.maxWidth < AppSizes.kGoodsColumnsWidth
                ? constraints.maxWidth
                : AppSizes.kDocSearchMaxWidth,
            child: PortalInput(
              controller: _search,
              hint: widget.hint,
              icon: Icons.search,
              onChanged: widget.onQuery,
            ),
          ),
          for (final f in DocFilter.values)
            PortalChoice(
              label: _label(f),
              count: widget.counts[f] ?? 0,
              selected: widget.filter == f,
              onTap: () => widget.onFilter(f),
            ),
        ],
      ),
    );
  }
}
