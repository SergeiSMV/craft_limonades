import 'package:flutter/material.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/utils/date_time_format.dart';
import '../../../../core/warehouse/internal_warehouses.dart';
import '../../../../core/widgets/neumorphic_line_tile.dart';
import '../../../../core/widgets/section_title.dart';
import '../../domain/stocktake_models.dart';

/// Выбор позиции снимка, когда у товара их несколько (партии, «Брак»): какую считаем.
/// «Другая партия» - излишек «Основного» с новой датой. `null` - передумали.
Future<({StocktakePosition? position})?> showPositionPickSheet(
  BuildContext context,
  List<StocktakePosition> positions,
) async {
  final names = {
    for (final w in await getIt<InternalWarehouses>().all()) w.id: w.name,
  };
  if (!context.mounted) return null;
  return showModalBottomSheet<({StocktakePosition? position})>(
    backgroundColor: AppColors.kNeumorphicBg,
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        padding: AppInsets.h8,
        children: [
          SectionTitle(title: t.stocktake.pickPosition),
          for (final p in positions)
            Padding(
              padding: AppInsets.bottom8,
              child: NeumorphicLineTile(
                title: t.stocktake.batch(
                  date: batchDate(p.productionDate ?? ''),
                ),
                subtitle: p.internalWarehouseId == null
                    ? null
                    : t.stocktake.warehouse(
                        name: names[p.internalWarehouseId] ?? '',
                      ),
                onTap: () => Navigator.of(ctx).pop((position: p)),
              ),
            ),
          Padding(
            padding: AppInsets.bottom8,
            child: NeumorphicLineTile(
              title: t.stocktake.otherBatch,
              onTap: () => Navigator.of(ctx).pop((position: null)),
            ),
          ),
        ],
      ),
    ),
  );
}
