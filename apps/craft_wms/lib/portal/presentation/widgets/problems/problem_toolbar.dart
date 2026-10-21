import 'package:flutter/material.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/gen/strings.g.dart';
import '../common/neumorphic_plate.dart';
import '../common/portal_filter_chip.dart';
import '../common/portal_search_box.dart';
import 'problem_filter.dart';

/// Панель над списком проблем (P6-07-3): поиск слева, фильтры справа — как у документов.
class ProblemToolbar extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return NeumorphicPlate(
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: AppSizes.kChipSpacing,
        runSpacing: AppSizes.kChipSpacing,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: AppSizes.kDocSearchMaxWidth,
            ),
            child: PortalSearchBox(
              hint: t.portal.problems.search,
              onChanged: onQuery,
            ),
          ),
          Wrap(
            spacing: AppSizes.kChipSpacing,
            runSpacing: AppSizes.kChipSpacing,
            children: [
              PortalFilterChip(
                label: t.portal.problems.filterOpen,
                count: counts[ProblemFilter.open] ?? 0,
                dot: AppColors.kPrimary,
                selected: filter == ProblemFilter.open,
                onTap: () => onFilter(ProblemFilter.open),
              ),
              PortalFilterChip(
                label: t.portal.problems.filterResolved,
                count: counts[ProblemFilter.resolved] ?? 0,
                dot: AppColors.kGreenLime,
                selected: filter == ProblemFilter.resolved,
                onTap: () => onFilter(ProblemFilter.resolved),
              ),
              PortalFilterChip(
                label: t.portal.problems.filterAll,
                count: counts[ProblemFilter.all] ?? 0,
                selected: filter == ProblemFilter.all,
                onTap: () => onFilter(ProblemFilter.all),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
