import 'package:flutter/material.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/load_unit/box_code.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/utils/date_time_format.dart';
import '../../domain/stocktake_count.dart';

/// Подтверждение «Ячейка посчитана» (P10-04) - одно, со списком того, что не нашли: короба
/// уйдут в «Не найдено», россыпь - недостачей. `true` - отправить.
Future<bool> showCountFinishDialog(
  BuildContext context,
  StocktakeCount count,
) async {
  final missing = count.missing;
  final text = RegularTextStyles().regularInter14.copyWith(
    color: AppColors.kTextMain,
  );
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      insetPadding: AppInsets.h8,
      title: Text(t.stocktake.finishTitle),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                missing.isEmpty
                    ? t.stocktake.finishAllFound
                    : t.stocktake.finishMissing,
                style: text,
              ),
              AppBoxes.kHeight8,
              for (final p in missing)
                Text(
                  p.isBox
                      ? t.stocktake.finishMissingBox(
                          code: boxCode(p.loadUnitId!, czCode: p.czCode),
                        )
                      : t.stocktake.finishMissingLoose(
                          name: p.good?.name ?? '',
                          date: batchDate(p.productionDate ?? ''),
                        ),
                  style: text.copyWith(color: AppColors.kDanger),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(t.stocktake.finishNo),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(t.stocktake.finishYes),
        ),
      ],
    ),
  );
  return ok ?? false;
}
