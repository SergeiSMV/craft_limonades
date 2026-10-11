import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart';

import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';
import '../common/neumorphic_plate.dart';
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
            child: _SearchBox(hint: hint, onChanged: onQuery),
          ),
          // Wrap, а не Row: на телефоне три чипа в строку не помещаются — последний переносится,
          // а не вылезает за плашку.
          Wrap(
            spacing: AppSizes.kChipSpacing,
            runSpacing: AppSizes.kChipSpacing,
            children: [
              _FilterChip(
                label: t.portal.documents.filterAll,
                count: counts[DocFilter.all] ?? 0,
                selected: filter == DocFilter.all,
                onTap: () => onFilter(DocFilter.all),
              ),
              _FilterChip(
                label: t.portal.documents.filterWaiting,
                count: counts[DocFilter.waiting] ?? 0,
                dot: AppColors.kPrimary,
                selected: filter == DocFilter.waiting,
                onTap: () => onFilter(DocFilter.waiting),
              ),
              _FilterChip(
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

/// Поле поиска — вдавленное, как поле поиска на ТСД.
class _SearchBox extends StatelessWidget {
  const _SearchBox({required this.hint, required this.onChanged});

  final String hint;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Neumorphic(
      style: NeumorphicStyle(
        color: AppColors.kNeumorphicBg,
        shadowLightColor: AppColors.kNeumorphicLight,
        shadowDarkColor: AppColors.kNeumorphicDark,
        intensity: 1,
        depth: AppSizes.kNeumorphicInsetDepth,
        shape: NeumorphicShape.flat,
        boxShape: NeumorphicBoxShape.roundRect(AppBorders.kCircular12),
      ),
      child: TextField(
        onChanged: onChanged,
        style: RegularTextStyles().regularInter14.copyWith(
          color: AppColors.kTextMain,
        ),
        cursorColor: AppColors.kTextMain,
        decoration: InputDecoration(
          isDense: true,
          // Без рамок и заливки темы портала: поле — сама вдавленная плашка, янтарная рамка
          // в фокусе и белый фон темы сделали бы его обычным полем поверх неё.
          filled: false,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          contentPadding: AppInsets.searchBox,
          prefixIcon: const Icon(
            Icons.search,
            size: AppSizes.kIcon20,
            color: AppColors.kTextMuted,
          ),
          hintText: hint,
          hintStyle: RegularTextStyles().regularInter14.copyWith(
            color: AppColors.kSidebarMuted,
          ),
        ),
      ),
    );
  }
}

/// Фильтр-чип в стиле пункта бокового меню: точка состояния, подпись, счётчик.
class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
    this.dot,
  });

  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  /// Цвет точки состояния; `null` — без точки («Все»).
  final Color? dot;

  @override
  Widget build(BuildContext context) {
    final content = Padding(
      padding: AppInsets.filterChip,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dot != null) ...[
            Container(
              width: AppSizes.kDotMark,
              height: AppSizes.kDotMark,
              decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
            ),
            AppBoxes.kWidth8,
          ],
          Text(
            label,
            style:
                (selected
                        ? SemiboldTextStyles().semiboldInter14
                        : RegularTextStyles().regularInter14)
                    .copyWith(color: AppColors.kTextMain),
          ),
          AppBoxes.kWidth8,
          Text(
            '$count',
            style: RegularTextStyles().regularInter12.copyWith(
              color: AppColors.kTextMuted,
            ),
          ),
        ],
      ),
    );
    if (selected) {
      return Neumorphic(
        style: NeumorphicStyle(
          color: AppColors.kNeumorphicBg,
          shadowLightColor: AppColors.kNeumorphicLight,
          shadowDarkColor: AppColors.kNeumorphicDark,
          intensity: 1,
          depth: AppSizes.kNeumorphicInsetDepth,
          shape: NeumorphicShape.flat,
          boxShape: NeumorphicBoxShape.roundRect(AppBorders.kCircular12),
        ),
        child: content,
      );
    }
    return Material(
      color: Colors.transparent,
      shape: const RoundedRectangleBorder(borderRadius: AppBorders.kCircular12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        hoverColor: AppColors.kBorder,
        child: content,
      ),
    );
  }
}
