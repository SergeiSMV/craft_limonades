import 'package:flutter/material.dart';

import '../../../../core/gen/strings.g.dart';
import '../../../../core/printer/load_unit_label.dart';
import '../../../../core/utils/date_time_format.dart';
import '../../../../core/widgets/section_title.dart';
import '../../domain/cz_scan.dart';
import '../cz_labels.dart';
import 'cz_lines.dart';

/// Блок «Марка Честного знака» в карточке товара - открыта сканом марки (CZ-04).
///
/// Что: данные ЧЗ (наименование по ЧЗ, статус, даты, владелец) и что знает склад - где марка
/// лежит и когда пришла. Это история марки на сегодня; журнал движений марки - CZ-06.
/// Наименование по ЧЗ показывается отдельно от наименования товара: они могут не совпадать.
class CzMarkSection extends StatelessWidget {
  const CzMarkSection({super.key, required this.scan});

  /// Ответ на скан марки.
  final CzScanResult scan;

  @override
  Widget build(BuildContext context) {
    final s = scan;
    final m = s.mark;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionTitle(title: t.czScan.sectionMark),
        czCard([
          if (s.productName != null)
            czText(t.czScan.czNameLine(name: s.productName!)),
          if (s.status != null)
            czText(t.czScan.czStatusLine(status: czStatusLabel(s.status))),
          if (s.producedDate != null)
            czText(t.czScan.producedLine(date: fullDate(s.producedDate!))),
          if (s.expirationDate != null)
            czText(t.czScan.expiresLine(date: fullDate(s.expirationDate!))),
          if (s.ownerName != null)
            czText(t.czScan.ownerLine(owner: s.ownerName!)),
          ..._wms(m),
          czMuted(t.czScan.codeLine(code: s.code)),
        ]),
      ],
    );
  }

  /// Что о марке знает склад: где лежит и когда пришла; не числится - так и сказать.
  List<Widget> _wms(CzMarkInWms? m) {
    if (m == null) return [czText(t.czScan.notInWms)];
    return [
      if (!m.inStock)
        czText(t.czScan.wmsStatusLine(status: wmsMarkStatusLabel(m.status))),
      if (m.loadUnitId != null)
        czText(
          t.czScan.boxLine(
            code: LoadUnitLabel(m.loadUnitId!).shortCodeFormatted,
          ),
        ),
      if (m.inStock)
        m.cellAddress != null
            ? czText(t.czScan.cellLine(address: m.cellAddress!))
            : czText(t.czScan.notPlaced),
      czMuted(t.czScan.receivedMeta(time: fullDateTime(m.receivedAt))),
    ];
  }
}
