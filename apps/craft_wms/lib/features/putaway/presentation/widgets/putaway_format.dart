import '../../../../core/gen/strings.g.dart';
import '../../../../core/printer/load_unit_label.dart';
import '../../../../core/utils/qty_format.dart';
import '../../../tasks/presentation/widgets/common/task_format.dart';
import '../bloc/putaway_models.dart';

/// Как назвать взятое: короб — его коротким кодом с ярлыка, россыпь — товаром, партией и
/// количеством.
String pickTitle(PutawayPick p) => p.isBox
    ? t.putaway.box(code: LoadUnitLabel(p.loadUnitId!).shortCodeFormatted)
    : t.putaway.loose(
        name: p.good?.name ?? '',
        date: batchDate(p.productionDate ?? ''),
        qty: fmtQty(p.qty ?? 0),
        uom: p.good?.uom ?? '',
      );
