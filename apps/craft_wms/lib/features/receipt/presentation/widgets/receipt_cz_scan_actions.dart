import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/gen/strings.g.dart';
import '../../../cz/domain/cz_intake.dart';
import '../../../cz/domain/cz_scan.dart';
import '../../../cz/presentation/widgets/cz_intake_scan.dart';
import '../bloc/receipt_cubit.dart';
import 'receipt_label_actions.dart';

/// Скан марки или короба «Честного знака» на приёмке (CZ-05).
///
/// Что: код читается общим чтением прихода ([CzIntakeScan]); короб ЧЗ ложится новой ГЕ со своим
/// составом, марка или групповая упаковка — единицами в текущий короб или россыпью.
/// Зачем отдельно от скана ШК: ветка только онлайн (долг 17) и со своими отказами; в общем
/// миксине скана она растворила бы его логику.
mixin ReceiptCzScanActions<T extends StatefulWidget>
    on State<T>, ReceiptLabelActions<T>, CzIntakeScan<T> {
  /// Короб, в который ложатся строки этого экрана; `null` — штучно.
  String? get scanBoxId;

  /// Отсканирован короб этой приёмки — экран решает, открыть ли его.
  void onBoxScanned(String boxId);

  ReceiptCubit get _receipt => context.read<ReceiptCubit>();

  /// Короб экрана — закрытый короб ЧЗ: в него ничего не добавляют.
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

  /// Скан кода ЧЗ: прочитать, проверить и положить в приёмку.
  Future<void> onCzScan(String code) async {
    if (inCzBox) {
      snack(t.receipt.czBoxClosed);
      return;
    }
    final read = await readCzIntake(code);
    if (read == null || !mounted) return;
    _add(read);
  }

  /// Положить прочитанное в приёмку и сказать кладовщику, что легло.
  void _add(CzIntakeRead read) {
    final scan = read.scan;
    final CzIntakeAdd result;
    if (scan.kind == CzCodeKind.box) {
      result = _receipt
          .addCzBox(code: scan.code, lines: read.lines, groups: read.groups)
          .result;
    } else {
      result = _receipt.addCzMarks(
        lines: read.lines,
        groups: read.groups,
        boxId: scanBoxId,
      );
    }
    switch (result) {
      case CzIntakeAdd.duplicate:
        snack(t.receipt.czDuplicate);
      case CzIntakeAdd.czBoxClosed:
        snack(t.receipt.czBoxClosed);
      case CzIntakeAdd.added:
        snack(
          [
            scan.kind == CzCodeKind.box
                ? t.receipt.czBoxAdded(count: read.units)
                : t.receipt.czMarksAdded(count: read.units),
            if (scan.unreadable.isNotEmpty)
              t.receipt.czUnreadable(count: scan.unreadable.length),
            if (read.hasDiscrepancy) t.receipt.czDiscrepancyAdded,
          ].join('\n'),
        );
    }
  }
}
