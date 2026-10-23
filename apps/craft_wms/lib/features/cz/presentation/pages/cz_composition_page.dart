import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/utils/date_time_format.dart';
import '../../../../core/widgets/page_header.dart';
import '../../../../core/widgets/section_title.dart';
import '../../../../core/widgets/system_ui_wrapper.dart';
import '../../domain/cz_scan.dart';
import '../cz_labels.dart';
import '../widgets/cz_lines.dart';

/// Состав упаковки «Честного знака» по ЧЗ (CZ-04): короб, ещё не принятый на склад, или
/// групповая упаковка. Принятый короб открывается карточкой ГЕ — там его содержимое по складу.
///
/// Строка состава — товар и партия: единицы сведены по дате производства единицы (ADR-0017).
/// Всё пришло ответом на скан, поэтому экран открывается без запроса.
@RoutePage()
class CzCompositionPage extends StatelessWidget {
  const CzCompositionPage({super.key, required this.scan});

  /// Ответ на скан упаковки.
  final CzScanResult scan;

  /// Вернуться к поиску.
  void goBack(BuildContext context) => context.router.maybePop();

  @override
  Widget build(BuildContext context) {
    final s = scan;
    final isBox = s.kind == CzCodeKind.box;
    return SystemUiWrapper(
      child: Scaffold(
        backgroundColor: AppColors.kBg,
        appBar: AppBar(
          automaticallyImplyLeading: false,
          backgroundColor: AppColors.kBg,
          title: PageHeader(
            title: isBox ? t.czScan.boxTitle : t.czScan.groupTitle,
            textColor: AppColors.kSidebarHover,
            goBack: () => goBack(context),
          ),
        ),
        body: SafeArea(
          top: false,
          child: ListView(
            padding: AppInsets.h8 + AppInsets.v16,
            children: [
              czCard([
                czStrong(t.czScan.unitsLine(count: s.units)),
                if (isBox && s.loadUnitId == null) czText(t.czScan.notAccepted),
                if (s.status != null)
                  czText(
                    t.czScan.czStatusLine(status: czStatusLabel(s.status)),
                  ),
                if (s.ownerName != null)
                  czText(t.czScan.ownerLine(owner: s.ownerName!)),
                if (s.unreadable.isNotEmpty)
                  czText(t.czScan.unreadableLine(count: s.unreadable.length)),
                czMuted(t.czScan.codeLine(code: s.code)),
              ]),
              AppBoxes.kHeight8,
              SectionTitle(title: t.czScan.sectionComposition),
              for (final line in s.composition) ...[
                _lineCard(line),
                AppBoxes.kHeight8,
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Строка состава: товар (или «не привязан» с GTIN), партия, количество.
  Widget _lineCard(CzCompositionLine l) => czCard([
    czStrong(l.productName),
    czText(
      l.good != null
          ? t.czScan.goodLine(name: l.good!.name)
          : t.czScan.goodUnknown(gtin: l.gtin),
    ),
    if (l.producedDate != null)
      czText(t.czScan.batchLine(date: fullDate(l.producedDate!))),
    czText(t.czScan.qtyLine(count: l.count)),
  ]);
}
