import 'package:flutter/material.dart';

import '../../../../../core/constants/app_boxes.dart';
import '../../../../../core/constants/app_colors.dart';
import '../../../../../core/constants/app_insets.dart';
import '../../../../../core/gen/strings.g.dart';
import '../../../../../core/theme/bold_text.dart';
import '../../../../../core/theme/regular_text.dart';
import '../../../../../core/theme/semibold_text.dart';
import '../../../../../core/utils/date_time_format.dart';
import '../../../../../core/utils/qty_format.dart';
import '../../../../../core/widgets/detail_card.dart';
import '../../../domain/contents_entities.dart';
import 'pending_mark.dart';

/// Строка содержимого: товар, партия и количество — в коробе или россыпью в ячейке.
class ContentLineTile extends StatelessWidget {
  const ContentLineTile({super.key, required this.line});

  final ContentLine line;

  @override
  Widget build(BuildContext context) {
    return DetailCard(
      padding: AppInsets.all12,
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  line.goodName ?? t.contents.unknownGood,
                  style: BoldTextStyles().boldInter14.copyWith(
                    color: AppColors.kSidebarHover,
                  ),
                ),
                Text(
                  t.contents.batch(date: batchDate(line.productionDate)),
                  style: RegularTextStyles().regularInter12.copyWith(
                    color: AppColors.kTextMuted,
                  ),
                ),
                if (line.pending) const PendingMark(),
              ],
            ),
          ),
          AppBoxes.kWidth12,
          Padding(
            padding: AppInsets.right8,
            child: Text(
              fmtQty(line.qty),
              style: SemiboldTextStyles().semiboldInter18.copyWith(
                color: AppColors.kSidebarHover,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
