import 'package:flutter/material.dart';

import '../../../../core/di/injection.dart';
import '../../../../core/error/failure.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/printer/load_unit_label.dart';
import '../../../../core/widgets/bind_prompt_dialog.dart';
import '../../../stock/data/catalog_models.dart';
import '../../../stock/data/catalog_repository.dart';
import '../../domain/cz_intake.dart';
import '../../domain/cz_scan.dart';
import '../cz_labels.dart';

/// Прочитанный код ЧЗ, готовый лечь в приход: ответ скана, строки по товару и партии и
/// групповые упаковки.
class CzIntakeRead {
  const CzIntakeRead({
    required this.scan,
    required this.lines,
    required this.groups,
  });

  final CzScanResult scan;
  final List<CzIntakeLine> lines;
  final List<CzGroupDraft> groups;

  /// Сколько единиц (марок) прочитано.
  int get units => lines.fold<int>(0, (n, l) => n + l.marks.length);

  /// Есть ли марки с расхождением — они уйдут в «Изолятор».
  bool get hasDiscrepancy =>
      lines.any((l) => l.marks.any((m) => m.discrepancy != null));
}

/// Чтение кода «Честного знака» для прихода — общее для приёмки (CZ-05) и «Ввода остатков»
/// (ADHOC-46).
///
/// Что: код читается из ЧЗ через сервер, проверяется (короб уже на складе, марка уже числится,
/// нет даты производства), незнакомый GTIN привязывается поиском, как незнакомый ШК. Итог —
/// [CzIntakeRead]; куда он ляжет, решает экран.
/// Зачем общее: оба прихода читают ЧЗ одинаково, а две копии разошлись бы на первой правке.
mixin CzIntakeScan<T extends StatefulWidget> on State<T> {
  /// Показать сообщение экрана.
  void snack(String text);

  /// Выбрать товар из номенклатуры (для привязки ШК незнакомого GTIN).
  Future<Good?> pickGood();

  /// Короб ЧЗ с этим кодом уже есть в этом приходе — экран его открывает.
  /// `true` — короб найден и обработан: читать код дальше незачем.
  bool openOwnCzBox(String code);

  /// Прочитать код ЧЗ. `null` — читать нечего или нельзя; причину кладовщик уже увидел.
  Future<CzIntakeRead?> readCzIntake(String code) async {
    snack(t.czScan.reading);
    final res = await getIt<CzScanRepository>().scan(code);
    if (!mounted) return null;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    if (res.isLeft) {
      snack(_failureText(res.left));
      return null;
    }
    final scan = res.right;
    if (!_acceptable(scan)) return null;
    final goods = await _goodsOf(scan);
    if (goods == null || !mounted) return null;
    if (czScanGaps(scan, goods).noDate) {
      snack(t.czScan.noDate);
      return null;
    }
    final lines = czIntakeLines(scan, goods);
    if (lines.isEmpty) {
      snack(t.czScan.noUnits);
      return null;
    }
    return CzIntakeRead(scan: scan, lines: lines, groups: czIntakeGroups(scan));
  }

  /// Можно ли брать код в приход: короб не принят на склад раньше (а уже отсканированный в
  /// этом приходе открывается), марки в WMS нет. Отказ по марке называет, где она лежит или
  /// куда ушла (ADHOC-53): иначе кладовщику не найти её.
  bool _acceptable(CzScanResult scan) {
    switch (scan.kind) {
      case CzCodeKind.box:
        if (scan.loadUnitId != null) {
          snack(t.czScan.boxOnStock);
          return false;
        }
        if (openOwnCzBox(scan.code)) return false;
      case CzCodeKind.unit:
        final mark = scan.mark;
        if (mark != null) {
          snack(markTakenText(mark));
          return false;
        }
      case CzCodeKind.group:
        break;
    }
    return true;
  }

  /// Почему марку не принять: где она на складе (короб, ячейка) или что с ней стало.
  String markTakenText(CzMarkInWms m) {
    if (!m.inStock) {
      return t.czScan.markWasOnStock(status: wmsMarkStatusLabel(m.status));
    }
    final place = [
      if (m.loadUnitId != null)
        t.czScan.markPlaceBox(
          code: LoadUnitLabel(m.loadUnitId!).shortCodeFormatted,
        ),
      if (m.cellAddress != null)
        t.czScan.markPlaceCell(address: m.cellAddress!)
      else
        t.czScan.markPlaceNone,
    ].join(', ');
    return t.czScan.markOnStockAt(place: place);
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

  /// Незнакомый GTIN: спросить, выбрать товар и привязать к нему ШК из марки. Привязка уходит
  /// операцией очереди и заодно помечает товар маркируемым — поэтому товар возвращается уже
  /// маркируемым. Исход привязки не разбираем: очередь примет операцию в любом случае.
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
    await getIt<CatalogRepository>().bindBarcode(
      goodId: good.id,
      barcode: barcode,
      fromCzMark: true,
    );
    return good.copyWith(czMarked: true);
  }

  /// Текст отказа чтения ЧЗ: без связи — отдельно, отказ сервера — его словами.
  String _failureText(Failure f) => switch (f) {
    NetworkFailure() => t.czScan.offline,
    ServerFailure(:final message?) => t.czScan.failed(reason: message),
    _ => t.czScan.failedGeneric,
  };
}
