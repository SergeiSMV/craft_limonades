import 'package:flutter/material.dart';

import '../../../../../core/constants/app_insets.dart';
import '../../../../../core/gen/strings.g.dart';
import '../../../../../core/scanner/scan_code.dart';
import '../../../../../core/scanner/scan_event.dart';

/// Одно принятое событие сканера: разобранные поля + полный набор extras «как пришло».
///
/// Сырые extras показываем всегда: набор ключей у прошивок Urovo расходится, и если код не
/// распознан, единственный способ понять почему — увидеть исходный интент целиком.
class ScanEventTile extends StatelessWidget {
  const ScanEventTile({super.key, required this.event});

  final RawScanEvent event;

  /// Подпись типа кода на русском.
  String _kindLabel(ScanKind kind) => switch (kind) {
    ScanKind.good => t.scannerProbe.kinds.good,
    ScanKind.cell => t.scannerProbe.kinds.cell,
    ScanKind.cargoUnit => t.scannerProbe.kinds.cargoUnit,
    ScanKind.czMark => t.scannerProbe.kinds.czMark,
    ScanKind.czBox => t.scannerProbe.kinds.czBox,
    ScanKind.unknown => t.scannerProbe.kinds.unknown,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    final scan = event.scan;
    return Card(
      margin: AppInsets.all8,
      child: Padding(
        padding: AppInsets.all12,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(scan?.raw ?? t.scannerProbe.none, style: theme.titleMedium),
            Padding(
              padding: AppInsets.top4,
              child: Text(
                '${t.scannerProbe.kind}: ${scan == null ? t.scannerProbe.none : _kindLabel(scan.kind)}'
                ' · ${t.scannerProbe.aim}: ${event.aim ?? t.scannerProbe.none}'
                ' · ${t.scannerProbe.symbology}: ${event.symbology ?? t.scannerProbe.none}',
                style: theme.bodySmall,
              ),
            ),
            Text(
              '${t.scannerProbe.action}: ${event.action ?? t.scannerProbe.none}',
              style: theme.bodySmall,
            ),
            if (event.extras.isNotEmpty) ...[
              Padding(
                padding: AppInsets.top8,
                child: Text(t.scannerProbe.extras, style: theme.bodySmall),
              ),
              for (final entry in event.extras.entries)
                Text('${entry.key} = ${entry.value}', style: theme.bodySmall),
            ],
          ],
        ),
      ),
    );
  }
}
