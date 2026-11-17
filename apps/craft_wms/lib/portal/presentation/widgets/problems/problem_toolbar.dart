import 'package:flutter/material.dart';

import '../../../../core/constants/app_sizes.dart';
import '../../../../core/gen/strings.g.dart';
import '../ui/portal_choice.dart';
import '../ui/portal_input.dart';
import 'problem_filter.dart';

/// Панель над списком проблем (P6-07-3, плоский стиль - ADHOC-56): поиск и фильтры со
/// счётчиками - как у документов. В узком окне поиск занимает строку, фильтры - под ним.
class ProblemToolbar extends StatefulWidget {
  const ProblemToolbar({
    super.key,
    required this.onQuery,
    required this.filter,
    required this.counts,
    required this.onFilter,
  });

  final ValueChanged<String> onQuery;
  final ProblemFilter filter;
  final Map<ProblemFilter, int> counts;
  final ValueChanged<ProblemFilter> onFilter;

  @override
  State<ProblemToolbar> createState() => _ProblemToolbarState();
}

class _ProblemToolbarState extends State<ProblemToolbar> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// Подпись фильтра.
  String _label(ProblemFilter f) => switch (f) {
    ProblemFilter.open => t.portal.problems.filterOpen,
    ProblemFilter.resolved => t.portal.problems.filterResolved,
    ProblemFilter.all => t.portal.problems.filterAll,
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
              hint: t.portal.problems.search,
              icon: Icons.search,
              onChanged: widget.onQuery,
            ),
          ),
          for (final f in ProblemFilter.values)
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
