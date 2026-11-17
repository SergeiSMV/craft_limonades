import 'package:flutter/material.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../domain/cell_count_check.dart';
import '../../../../core/utils/doc_number.dart';

/// Можно ли двигать товар через ячейку [cellId] (ADHOC-48): ячейку движения проверяют все
/// потоки - перемещение, размещение, проблемы склада, возврат поставщику.
///
/// Ячейка на подсчёте пересчёта - предупреждение «кто считает, какой пересчёт» с выбором:
/// «Отмена» - `false`, «Всё равно» - `true` (подсчёт собьётся, ячейку посчитают заново).
/// Запрета нет: начатую и брошенную ячейку склад должен мочь освободить. Без связи -
/// `true` без вопроса, сервер сам пометит подсчёт сбитым.
Future<bool> allowMoveThroughCell(BuildContext context, String cellId) async {
  final check = getIt<CellCountCheck>();
  final count = await check.counting(cellId);
  if (count == null) return true;
  if (!context.mounted) return false;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => _CellUnderCountDialog(count: count),
  );
  if (ok ?? false) {
    check.confirmed(cellId, count);
    return true;
  }
  return false;
}

/// Окно «Ячейка на пересчёте»: каждый факт - своей подписанной строкой.
class _CellUnderCountDialog extends StatelessWidget {
  const _CellUnderCountDialog({required this.count});

  final CellUnderCount count;

  @override
  Widget build(BuildContext context) {
    final text = RegularTextStyles().regularInter14.copyWith(
      color: AppColors.kTextMain,
    );
    return AlertDialog(
      insetPadding: AppInsets.h8,
      title: Text(t.stocktake.underCountTitle),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(t.stocktake.underCountCell(cell: count.address), style: text),
            if (count.countedBy.isNotEmpty)
              Text(
                t.stocktake.underCountBy(name: count.countedBy),
                style: text,
              ),
            Text(
              t.stocktake.underCountNumber(number: docNumber(DocKind.stocktake, count.stocktakeNumber)),
              style: text,
            ),
            AppBoxes.kHeight8,
            Text(
              t.stocktake.underCountBody,
              style: text.copyWith(color: AppColors.kDanger),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(t.stocktake.underCountCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(t.stocktake.underCountGo),
        ),
      ],
    );
  }
}
