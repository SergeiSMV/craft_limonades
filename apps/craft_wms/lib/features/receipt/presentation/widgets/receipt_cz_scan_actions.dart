import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/di/injection.dart';
import '../../../../core/error/failure.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/widgets/bind_prompt_dialog.dart';
import '../../../cz/domain/cz_scan.dart';
import '../../../stock/data/catalog_models.dart';
import '../../../stock/data/catalog_repository.dart';
import '../bloc/receipt_cubit.dart';
import '../bloc/receipt_cz.dart';
import '../bloc/receipt_models.dart';
import 'receipt_label_actions.dart';

/// Скан марки или короба «Честного знака» на приёмке (CZ-05).
///
/// Что: код читается из ЧЗ через сервер, кладовщик видит, что принял и есть ли расхождение.
/// Короб ЧЗ ложится новой ГЕ со своим составом, марка или групповая упаковка — единицами в
/// текущий короб или россыпью. Незнакомый GTIN — привязка ШК поиском, как у незнакомого ШК.
/// Зачем отдельно от скана ШК: ветка только онлайн (долг 17) и со своими отказами; в общем
/// миксине скана она растворила бы его логику.
mixin ReceiptCzScanActions<T extends StatefulWidget>
    on State<T>, ReceiptLabelActions<T> {
  /// Короб, в который ложатся строки этого экрана; `null` — штучно.
  String? get scanBoxId;

  /// Выбрать товар из номенклатуры (для привязки ШК незнакомого GTIN).
  Future<Good?> pickGood();

  /// Отсканирован короб этой приёмки — экран решает, открыть ли его.
  void onBoxScanned(String boxId);

  ReceiptCubit get _receipt => context.read<ReceiptCubit>();

  /// Короб экрана — закрытый короб ЧЗ: в него ничего не добавляют.
  bool get inCzBox {
    final id = scanBoxId;
    return id != null && (_receipt.state.boxById(id)?.isCz ?? false);
  }

  /// Скан кода ЧЗ: прочитать, проверить и положить в приёмку.
  Future<void> onCzScan(String code) async {
    if (inCzBox) {
      snack(t.receipt.czBoxClosed);
      return;
    }
    snack(t.czScan.reading);
    final res = await getIt<CzScanRepository>().scan(code);
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    if (res.isLeft) {
      snack(_failureText(res.left));
      return;
    }
    final scan = res.right;
    if (!_acceptable(scan)) return;
    final goods = await _goodsOf(scan);
    if (goods == null || !mounted) return;
    final gaps = czScanGaps(scan, goods);
    if (gaps.noDate) {
      snack(t.receipt.czNoDate);
      return;
    }
    final lines = czReceiptLines(scan, goods);
    if (lines.isEmpty) {
      snack(t.receipt.czNoUnits);
      return;
    }
    _add(scan, lines);
  }

  /// Можно ли принимать код: короб не принят раньше (а уже отсканированный в этой приёмке
  /// открывается), марка не числится на складе.
  bool _acceptable(CzScanResult scan) {
    switch (scan.kind) {
      case CzCodeKind.box:
        if (scan.loadUnitId != null) {
          snack(t.receipt.czBoxAccepted);
          return false;
        }
        final own = _receipt.state.czBoxByCode(scan.code);
        if (own != null) {
          onBoxScanned(own.id);
          return false;
        }
      case CzCodeKind.unit:
        if (scan.mark?.inStock ?? false) {
          snack(t.receipt.czMarkOnStock);
          return false;
        }
      case CzCodeKind.group:
        break;
    }
    return true;
  }

  /// Положить прочитанное в приёмку и сказать кладовщику, что легло.
  void _add(CzScanResult scan, List<ReceiptCzLine> lines) {
    final groups = czReceiptGroups(scan);
    final units = lines.fold<int>(0, (n, l) => n + l.marks.length);
    final ReceiptCzAdd result;
    if (scan.kind == CzCodeKind.box) {
      result = _receipt
          .addCzBox(code: scan.code, lines: lines, groups: groups)
          .result;
    } else {
      result = _receipt.addCzMarks(
        lines: lines,
        groups: groups,
        boxId: scanBoxId,
      );
    }
    switch (result) {
      case ReceiptCzAdd.duplicate:
        snack(t.receipt.czDuplicate);
      case ReceiptCzAdd.czBoxClosed:
        snack(t.receipt.czBoxClosed);
      case ReceiptCzAdd.added:
        final discrepancy = lines.any(
          (l) => l.marks.any((m) => m.discrepancy != null),
        );
        snack(
          [
            scan.kind == CzCodeKind.box
                ? t.receipt.czBoxAdded(count: units)
                : t.receipt.czMarksAdded(count: units),
            if (scan.unreadable.isNotEmpty)
              t.receipt.czUnreadable(count: scan.unreadable.length),
            if (discrepancy) t.receipt.czDiscrepancyAdded,
          ].join('\n'),
        );
    }
  }

  /// Товары справочника по GTIN скана. Известный — из справочника терминала; незнакомый —
  /// привязка ШК (EAN-13 из GTIN) к выбранному товару с пометкой «из марки». `null` —
  /// кладовщик отказался от привязки или справочник терминала не загружен.
  Future<Map<String, Good>?> _goodsOf(CzScanResult scan) async {
    final refs = <String, CzGood?>{
      if (scan.kind == CzCodeKind.unit && scan.gtin != null)
        scan.gtin!: scan.good,
      for (final l in scan.composition) l.gtin: l.good,
    };
    final names = <String, String>{
      if (scan.gtin != null) scan.gtin!: scan.productName ?? scan.code,
      for (final l in scan.composition) l.gtin: l.productName,
    };
    final catalog = getIt<CatalogRepository>();
    final goods = <String, Good>{};
    for (final e in refs.entries) {
      final ref = e.value;
      final good = ref != null
          ? await catalog.goodById(ref.id)
          : await _bindGtin(e.key, names[e.key] ?? e.key);
      if (!mounted) return null;
      if (good == null) {
        if (ref != null) snack(t.czScan.goodNotLoaded);
        return null;
      }
      goods[e.key] = good;
    }
    return goods;
  }

  /// Незнакомый GTIN: спросить, выбрать товар и привязать к нему ШК из марки. Товар
  /// возвращается уже маркируемым — таким его сделает и привязка.
  Future<Good?> _bindGtin(String gtin, String name) async {
    final barcode = ean13FromGtin(gtin);
    final confirmed = await showBindPromptDialog(
      context,
      title: t.czScan.bindPromptTitle,
      body: t.czScan.bindPromptBody(name: name, barcode: barcode),
      confirmLabel: t.stockListScreen.bindConfirm,
      cancelLabel: t.stockListScreen.bindCancel,
    );
    if (!confirmed || !mounted) return null;
    final good = await pickGood();
    if (good == null || !mounted) return null;
    await _receipt.bindCzBarcode(goodId: good.id, barcode: barcode);
    return good.copyWith(czMarked: true);
  }

  /// Текст отказа чтения ЧЗ: без связи — отдельно, отказ сервера — его словами.
  String _failureText(Failure f) => switch (f) {
    NetworkFailure() => t.receipt.czOffline,
    ServerFailure(:final message?) => t.receipt.czFailed(reason: message),
    _ => t.receipt.czFailedGeneric,
  };
}
