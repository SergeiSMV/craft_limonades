import 'package:flutter/material.dart';

import '../../../../core/constants/app_sizes.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../features/stock/data/catalog_models.dart';
import '../ui/portal_button.dart';
import '../ui/portal_input.dart';
import '../ui/portal_select.dart';

/// Панель над списком «Номенклатуры склада» (ADHOC-56): поиск, фильтры по группе и поставщику
/// и «Загрузить из 1С» (по праву загрузки).
///
/// Раскладка — переносом: в широком окне всё в строку, в узком поиск занимает строку целиком,
/// фильтры и кнопка уходят под него.
class GoodsToolbar extends StatelessWidget {
  const GoodsToolbar({
    super.key,
    required this.search,
    required this.onSearch,
    required this.groups,
    required this.groupId,
    required this.onGroup,
    required this.suppliers,
    required this.supplierId,
    required this.onSupplier,
    this.onImport,
  });

  final TextEditingController search;
  final ValueChanged<String> onSearch;
  final List<NomenclatureGroup> groups;
  final String? groupId;
  final ValueChanged<String?> onGroup;
  final List<Supplier> suppliers;
  final String? supplierId;
  final ValueChanged<String?> onSupplier;

  /// Открыть загрузку из 1С; `null` — права нет, кнопки нет.
  final VoidCallback? onImport;

  @override
  Widget build(BuildContext context) {
    final g = t.portal.goods;
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
              controller: search,
              hint: g.searchHint,
              icon: Icons.search,
              onChanged: onSearch,
            ),
          ),
          PortalSelect(
            label: g.group,
            allLabel: g.all,
            options: [for (final x in groups) (id: x.id, label: x.name)],
            value: groupId,
            onChanged: onGroup,
          ),
          PortalSelect(
            label: g.supplier,
            allLabel: g.all,
            options: [for (final x in suppliers) (id: x.id, label: x.name)],
            value: supplierId,
            onChanged: onSupplier,
          ),
          if (onImport != null)
            PortalButton(
              label: g.import,
              icon: Icons.upload_file_outlined,
              onPressed: onImport!,
            ),
        ],
      ),
    );
  }
}
