import '../../../../core/gen/strings.g.dart';
import '../../../../core/load_unit/box_code.dart';
import '../../../../core/utils/qty_format.dart';
import '../../../tasks/presentation/widgets/common/task_format.dart';
import '../bloc/putaway_models.dart';

/// Как назвать взятое: короб - его коротким кодом с ярлыка, россыпь - товаром, партией и
/// количеством.
String pickTitle(PutawayPick p) => p.isBox
    ? t.putaway.box(code: boxCode(p.loadUnitId!, czCode: p.czCode))
    : t.putaway.loose(
        name: p.good?.name ?? '',
        date: batchDate(p.productionDate ?? ''),
        qty: fmtQty(p.qty ?? 0),
        uom: p.good?.uom ?? '',
      );
