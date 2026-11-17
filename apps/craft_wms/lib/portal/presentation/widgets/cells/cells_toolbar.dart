import 'package:flutter/material.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../domain/cells/cells_view.dart';
import '../ui/portal_choice.dart';
import '../ui/portal_input.dart';
import '../ui/portal_select.dart';
import 'cells_controller.dart';

/// Панель над списком ячеек (ADHOC-57): поиск по адресу, фильтры «Стеллаж» и «Признак»,
/// действия страницы ([trailing]) и под ними - быстрый фильтр по балке со счётчиками.
///
/// Счётчики балки считаются под остальные фильтры: видно, сколько больших и малых в
/// выбранном стеллаже, не переключая фильтр. Раскладка - переносом, как у номенклатуры.
class CellsToolbar extends StatelessWidget {
  const CellsToolbar({
    super.key,
    required this.c,
    required this.search,
    required this.onSearch,
    this.trailing = const [],
  });

  final CellsController c;
  final TextEditingController search;
  final ValueChanged<String> onSearch;
  final List<Widget> trailing;

  void onRack(String? id) => c.setFilter(c.filter.copyWith(rackId: () => id));

  void onFlag(String? id) => c.setFilter(
    c.filter.copyWith(
      flag: () => id == null ? null : FlagFilter.values.byName(id),
    ),
  );

  void onBeam(BeamFilter b) => c.setFilter(c.filter.copyWith(beam: b));

  @override
  Widget build(BuildContext context) {
    final s = t.portal.cells;
    final view = c.view;
    final base = view?.filtered(c.filter, ignoreBeam: true) ?? const [];
    final small = base.where((x) => x.labelSmall).length;
    final counts = {
      BeamFilter.all: base.length,
      BeamFilter.large: base.length - small,
      BeamFilter.small: small,
    };
    final labels = {
      BeamFilter.all: s.all,
      BeamFilter.large: s.beamLarge,
      BeamFilter.small: s.beamSmall,
    };
    return LayoutBuilder(
      builder: (context, constraints) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: AppSizes.kChipSpacing,
            runSpacing: AppSizes.kChipSpacing,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: constraints.maxWidth < AppSizes.kCellsColumnsWidth
                    ? constraints.maxWidth
                    : AppSizes.kCellsSearchWidth,
                child: PortalInput(
                  controller: search,
                  hint: s.search,
                  icon: Icons.search,
                  onChanged: onSearch,
                ),
              ),
              PortalSelect(
                label: s.rack,
                allLabel: s.all,
                options: [
                  for (final r in view?.racks ?? const [])
                    (id: r.id, label: r.code),
                ],
                value: c.filter.rackId,
                onChanged: onRack,
              ),
              PortalSelect(
                label: s.flag,
                allLabel: s.all,
                options: [
                  (id: FlagFilter.floor.name, label: s.flagFloor),
                  (id: FlagFilter.barcode.name, label: s.flagBarcode),
                  (id: FlagFilter.noBarcode.name, label: s.flagNoBarcode),
                  (id: FlagFilter.sideCard.name, label: s.flagSideCard),
                  (id: FlagFilter.floorStorage.name, label: s.flagFloorStorage),
                ],
                value: c.filter.flag?.name,
                onChanged: onFlag,
              ),
              ...trailing,
            ],
          ),
          AppBoxes.kHeight16,
          Wrap(
            spacing: AppSizes.kChipSpacing,
            runSpacing: AppSizes.kChipSpacing,
            children: [
              for (final b in BeamFilter.values)
                PortalChoice(
                  label: labels[b]!,
                  count: counts[b],
                  selected: c.filter.beam == b,
                  onTap: () => onBeam(b),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
