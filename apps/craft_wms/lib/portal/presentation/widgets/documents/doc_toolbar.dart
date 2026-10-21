import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/gen/strings.g.dart';
import '../common/neumorphic_plate.dart';
import '../common/portal_filter_chip.dart';
import '../common/portal_search_box.dart';
import 'doc_filter.dart';

/// Панель над таблицей документов (ADHOC-26): поиск слева, фильтры по состоянию в 1С справа.
///
/// Фильтры выглядят как пункты бокового меню: выбранный вдавлен на чуть более тёмном фоне
/// с полужирной подписью, остальные лежат ровно и подсвечиваются при наведении. Счётчики —
/// по всему списку, без учёта поиска.
class DocToolbar extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return NeumorphicPlate(
      // Wrap, а не Row: на узком окне фильтры уходят под поиск, а не вылезают за край.
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 4,
        runSpacing: AppSizes.kChipSpacing,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: AppSizes.kDocSearchMaxWidth,
            ),
            child: PortalSearchBox(hint: hint, onChanged: onQuery),
          ),
          // Wrap, а не Row: на телефоне три чипа в строку не помещаются — последний переносится,
          // а не вылезает за плашку.
          Wrap(
            spacing: AppSizes.kChipSpacing,
            runSpacing: AppSizes.kChipSpacing,
            children: [
              PortalFilterChip(
                label: t.portal.documents.filterAll,
                count: counts[DocFilter.all] ?? 0,
                selected: filter == DocFilter.all,
                onTap: () => onFilter(DocFilter.all),
              ),
              PortalFilterChip(
                label: t.portal.documents.filterWaiting,
                count: counts[DocFilter.waiting] ?? 0,
                dot: AppColors.kPrimary,
                selected: filter == DocFilter.waiting,
                onTap: () => onFilter(DocFilter.waiting),
              ),
              PortalFilterChip(
                label: t.portal.documents.filterPosted,
                count: counts[DocFilter.posted] ?? 0,
                dot: AppColors.kGreenLime,
                selected: filter == DocFilter.posted,
                onTap: () => onFilter(DocFilter.posted),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
