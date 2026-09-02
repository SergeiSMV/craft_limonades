import 'package:flutter/material.dart';

import '../../../../../core/constants/app_insets.dart';
import '../../../../../core/constants/app_sizes.dart';
import '../../../../../core/gen/strings.g.dart';
import '../../../../../core/scanner/scan_event.dart';

/// Сводка опроса устройства: по каким признакам решено, что аппаратный сканер есть или нет.
///
/// Показываем все признаки, а не итоговый флаг: непрозрачное «да/нет» невозможно разобрать
/// на складе, когда сканер молчит, а приложение считает, что он есть.
class ProbeSummaryCard extends StatelessWidget {
  const ProbeSummaryCard({super.key, required this.probe});

  final ScannerProbe probe;

  @override
  Widget build(BuildContext context) {
    String yesNo(bool value) => value ? t.scannerProbe.yes : t.scannerProbe.no;
    final device = [
      probe.manufacturer,
      probe.model,
      probe.device,
    ].where((part) => part.isNotEmpty).join(' · ');
    return Card(
      margin: AppInsets.all8,
      child: Padding(
        padding: AppInsets.all12,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Row(label: t.scannerProbe.device, value: device),
            _Row(
              label: t.scannerProbe.hardwareScanner,
              value: yesNo(probe.available),
            ),
            _Row(
              label: t.scannerProbe.packages,
              value: probe.packages.join('\n'),
            ),
            _Row(
              label: t.scannerProbe.actions,
              value: probe.actions.join('\n'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Строка сводки «подпись — значение»; пустое значение показываем прочерком.
class _Row extends StatelessWidget {
  const _Row({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    return Padding(
      padding: AppInsets.v4,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: AppSizes.kProbeLabelWidth,
            child: Text(label, style: theme.bodySmall),
          ),
          Expanded(
            child: Text(
              value.isEmpty ? t.scannerProbe.none : value,
              style: theme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}
