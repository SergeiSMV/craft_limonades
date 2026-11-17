import 'package:flutter/material.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/semibold_text.dart';
import '../../../../core/utils/date_time_format.dart';
import '../../../../core/utils/qty_format.dart';
import '../../../../core/widgets/neumorphic_line_tile.dart';
import '../../../contents/domain/contents_entities.dart';
import 'move_format.dart';

/// Выбрать товар и партию из источника: что лежит и сколько его можно взять.
///
/// Нужен в двух случаях: у товара несколько партий (скан не говорит, какую взяли) и у товара
/// нет штрихкода (выбор вместо скана). Позиции - неоморфными плашками, как товары в «Остатках»:
/// это кнопки, и выглядят они кнопками.
Future<(ContentLine, double)?> showMoveGoodsSheet(
  BuildContext context,
  List<(ContentLine, double)> options,
) => showModalBottomSheet<(ContentLine, double)>(
  context: context,
  backgroundColor: AppColors.kNeumorphicBg,
  isScrollControlled: true,
  showDragHandle: true,
  constraints: BoxConstraints(
    maxHeight: MediaQuery.of(context).size.height * 0.85,
  ),
  builder: (ctx) => SafeArea(
    child: ListView(
      shrinkWrap: true,
      padding: AppInsets.h8 + AppInsets.bottom16,
      children: [
        Text(
          t.movement.batchTitle,
          style: SemiboldTextStyles().semiboldInter16,
        ),
        for (final o in options) ...[
          AppBoxes.kHeight8,
          NeumorphicLineTile(
            title: o.$1.goodName ?? o.$1.goodCode ?? '',
            subtitle: withWarehouse(
              t.movement.batch(date: batchDate(o.$1.productionDate)),
              o.$1.internalWarehouseName,
            ),
            trailing: '${fmtQty(o.$2)} ${o.$1.uom ?? ''}'.trim(),
            onTap: () => Navigator.of(ctx).pop(o),
          ),
        ],
      ],
    ),
  ),
);
