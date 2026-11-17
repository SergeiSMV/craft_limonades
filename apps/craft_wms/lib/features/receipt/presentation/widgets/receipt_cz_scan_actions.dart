import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/gen/strings.g.dart';
import '../../../cz/domain/cz_intake.dart';
import '../../../cz/domain/cz_intake_hold.dart';
import '../../../cz/domain/cz_scan.dart';
import '../../../cz/presentation/widgets/cz_intake_scan.dart';
import '../bloc/receipt_cubit.dart';
import 'receipt_label_actions.dart';

/// Скан марки или короба «Честного знака» на приёмке (CZ-05).
///
/// Что: код встаёт в общую очередь чтения прихода ([CzIntakeScan], ADHOC-70); прочитанный короб
/// ЧЗ ложится новой ГЕ со своим составом, марка или групповая упаковка - единицами в короб, где
/// её отсканировали, или россыпью.
/// Зачем отдельно от скана ШК: ветка только онлайн (долг 17) и со своими отказами; в общем
/// миксине скана она растворила бы его логику.
mixin ReceiptCzScanActions<T extends StatefulWidget>
    on State<T>, ReceiptLabelActions<T>, CzIntakeScan<T> {
  /// Отсканирован короб этой приёмки - экран решает, открыть ли его.
  void onBoxScanned(String boxId);

  ReceiptCubit get _receipt => context.read<ReceiptCubit>();

  /// Короб экрана - закрытый короб ЧЗ: в него ничего не добавляют.
  bool get inCzBox {
    final id = scanBoxId;
    return id != null && (_receipt.state.boxById(id)?.isCz ?? false);
  }

  /// Короб ЧЗ, уже отсканированный в этой приёмке, открывается.
  @override
  bool openOwnCzBox(String code) {
    final own = _receipt.state.czBoxByCode(code);
    if (own == null) return false;
    onBoxScanned(own.id);
    return true;
  }

  /// Марка или упаковка уже в приёмке - повтор не читается.
  @override
  bool czAlreadyHere(String key) =>
      _receipt.state.hasMark(key) ||
      _receipt.state.czGroups.any((g) => g.code == key);

  @override
  CzIntakeHold get czHold => _receipt.czHold;

  @override
  CzIntakeTexts get czTexts => CzIntakeTexts(
    marksAdded: (n) => t.receipt.czMarksAdded(count: n),
    boxAdded: (n) => t.receipt.czBoxAdded(count: n),
    duplicate: t.receipt.czDuplicate,
    boxClosed: t.receipt.czBoxClosed,
    unreadable: (n) => t.receipt.czUnreadable(count: n),
    discrepancy: t.receipt.czDiscrepancyAdded,
  );

  /// Скан кода ЧЗ: в закрытый короб ЧЗ - отказ, иначе в очередь чтения.
  void onCzScan(String code) {
    if (inCzBox) {
      snack(t.receipt.czBoxClosed);
      return;
    }
    czEnqueue(code);
  }

  /// Положить прочитанное: короб ЧЗ - новой ГЕ, марки - в короб скана или россыпью.
  @override
  CzIntakeAdd czApply(CzIntakeRead read, {String? boxId}) {
    if (read.scan.kind == CzCodeKind.box) {
      return _receipt
          .addCzBox(
            code: read.scan.code,
            lines: read.lines,
            groups: read.groups,
          )
          .result;
    }
    return _receipt.addCzMarks(
      lines: read.lines,
      groups: read.groups,
      boxId: boxId,
    );
  }
}
