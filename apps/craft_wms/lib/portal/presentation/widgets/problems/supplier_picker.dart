import 'package:flutter/material.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/utils/search_text.dart';
import '../../../data/problems_repository.dart';
import '../common/portal_filter_chip.dart';
import '../common/portal_search_box.dart';

/// Выбор поставщика возврата (ADHOC-30): поле поиска портала и список под ним — пункты в стиле
/// фильтр-чипов, выбранный вдавлен. Вместо `DropdownMenu` с его темой: поставщиков сотни, и их
/// ищут по словам названия, а не листают.
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
  String _query = '';

  /// Запрос поиска изменился.
  void onQuery(String q) => setState(() => _query = q);

  @override
  Widget build(BuildContext context) {
    final words = searchWords(_query);
    // Выбранный — первым: подсказка из справочника видна сразу, без прокрутки.
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
        PortalSearchBox(
          hint: t.portal.problems.supplierHint,
          onChanged: onQuery,
        ),
        AppBoxes.kHeight8,
        ConstrainedBox(
          constraints: const BoxConstraints(
            maxHeight: AppSizes.kPortalPickListMaxHeight,
          ),
          child: shown.isEmpty
              ? Text(
                  t.portal.problems.notFound,
                  style: RegularTextStyles().regularInter14.copyWith(
                    color: AppColors.kTextMuted,
                  ),
                )
              : ListView.separated(
                  shrinkWrap: true,
                  itemCount: shown.length,
                  separatorBuilder: (_, _) => AppBoxes.kHeight4,
                  itemBuilder: (_, i) => Align(
                    alignment: Alignment.centerLeft,
                    child: PortalFilterChip(
                      label: shown[i].name,
                      selected: shown[i].id == widget.selectedId,
                      onTap: () => widget.onSelected(shown[i].id),
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}
