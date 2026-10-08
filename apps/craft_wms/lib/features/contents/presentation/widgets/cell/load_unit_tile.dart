import 'package:flutter/material.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import '../../../../../core/constants/app_boxes.dart';
import '../../../../../core/constants/app_colors.dart';
import '../../../../../core/constants/app_insets.dart';
import '../../../../../core/constants/app_sizes.dart';
import '../../../../../core/gen/strings.g.dart';
import '../../../../../core/printer/load_unit_label.dart';
import '../../../../../core/theme/bold_text.dart';
import '../../../../../core/theme/regular_text.dart';
import '../../../../../core/widgets/detail_card.dart';
import '../../../domain/contents_entities.dart';
import '../common/pending_mark.dart';

/// Короб в списке ячейки: короткий код с ярлыка и сколько в нём позиций. Касание — карточка.
///
/// Короткий код, а не идентификатор: кладовщик сверяет его с наклейкой на коробе глазами.
class LoadUnitTile extends StatelessWidget {
  const LoadUnitTile({super.key, required this.loadUnit, required this.onTap});

  final LoadUnitView loadUnit;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final code = LoadUnitLabel(loadUnit.id).shortCodeFormatted;
    return DetailCard(
      padding: EdgeInsets.zero,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: AppInsets.all12,
          child: Row(
            children: [
              Icon(
                MdiIcons.packageVariantClosed,
                size: AppSizes.kIcon28,
                color: AppColors.kPlacePin,
              ),
              AppBoxes.kWidth12,
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      t.contents.boxCode(code: code),
                      style: BoldTextStyles().boldInter16.copyWith(
                        color: AppColors.kSidebarHover,
                      ),
                    ),
                    Text(
                      t.contents.positions(count: loadUnit.lines.length),
                      style: RegularTextStyles().regularInter12.copyWith(
                        color: AppColors.kTextMuted,
                      ),
                    ),
                    if (loadUnit.pending) const PendingMark(),
                  ],
                ),
              ),
              Icon(
                MdiIcons.chevronRight,
                size: AppSizes.kIcon24,
                color: AppColors.kTextMuted,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
