import 'package:flutter/material.dart';

import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';
import '../../../../core/utils/search_text.dart';
import '../../../domain/problems/problems_repository.dart';
import '../ui/portal_input.dart';

/// Выбор поставщика возврата (ADHOC-30, плоский стиль - ADHOC-56): поле поиска и под ним
/// список строк в рамке с прокруткой, выбранный - полужирным с галочкой. Вместо
/// `DropdownMenu` с его темой: поставщиков сотни, и их ищут по словам названия, а не листают.
class SupplierPicker extends StatefulWidget {
  const SupplierPicker({
    super.key,
    required this.suppliers,
    required this.selectedId,
    required this.onSelected,
  });

  final List<PortalSupplier> suppliers;
  final String selectedId;
  final ValueChanged<String> onSelected;

  @override
  State<SupplierPicker> createState() => _SupplierPickerState();
}

class _SupplierPickerState extends State<SupplierPicker> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// Запрос поиска изменился.
  void onQuery(String q) => setState(() => _query = q);

  @override
  Widget build(BuildContext context) {
    final words = searchWords(_query);
    // Выбранный - первым: подсказка из справочника видна сразу, без прокрутки.
    final shown =
        [
          for (final s in widget.suppliers)
            if (words.every(normalizeSearchText(s.name).contains)) s,
        ]..sort(
          (a, b) =>
              (b.id == widget.selectedId ? 1 : 0) -
              (a.id == widget.selectedId ? 1 : 0),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        PortalInput(
          controller: _search,
          hint: t.portal.problems.supplierHint,
          icon: Icons.search,
          onChanged: onQuery,
        ),
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
              child: shown.isEmpty
                  ? Padding(
                      padding: AppInsets.cardRow,
                      child: Text(
                        t.portal.problems.notFound,
                        style: RegularTextStyles().regularInter13.copyWith(
                          color: AppColors.kTextMuted,
                        ),
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
                      itemBuilder: (_, i) => _SupplierRow(
                        name: shown[i].name,
                        selected: shown[i].id == widget.selectedId,
                        onTap: () => widget.onSelected(shown[i].id),
                      ),
                    ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Строка поставщика: название, у выбранного - полужирное с галочкой справа.
class _SupplierRow extends StatelessWidget {
  const _SupplierRow({
    required this.name,
    required this.selected,
    required this.onTap,
  });

  final String name;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    hoverColor: AppColors.kBg,
    child: Padding(
      padding: AppInsets.cardRow,
      child: Row(
        children: [
          Expanded(
            child: Text(
              name,
              style:
                  (selected
                          ? SemiboldTextStyles().semiboldInter13
                          : RegularTextStyles().regularInter13)
                      .copyWith(color: AppColors.kTextMain),
            ),
          ),
          if (selected)
            const Icon(
              Icons.check,
              size: AppSizes.kIcon18,
              color: AppColors.kButtonPrimary,
            ),
        ],
      ),
    ),
  );
}
