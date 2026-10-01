import 'package:flutter/material.dart';

import '../../../../../core/gen/strings.g.dart';
import '../../../../../core/printer/printer_device.dart';

/// Карточка состояния: что с Bluetooth, какой принтер выбран и есть ли соединение.
///
/// Признаки показываются раздельно, а не сводятся к «готов / не готов»: человеку на складе
/// нужно знать, что именно чинить — включить Bluetooth, выбрать принтер или подойти ближе.
class PrinterStatusCard extends StatelessWidget {
  const PrinterStatusCard({
    required this.status,
    required this.selected,
    super.key,
  });

  final PrinterStatus status;
  final PrinterDevice? selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.printerProbe.status, style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            if (!status.supported)
              Text(
                t.printerProbe.unsupported,
                style: theme.textTheme.bodyMedium,
              )
            else if (!status.enabled)
              Text(
                t.printerProbe.bluetoothOff,
                style: theme.textTheme.bodyMedium,
              )
            else
              Text(
                status.connected
                    ? t.printerProbe.connected
                    : t.printerProbe.disconnected,
                style: theme.textTheme.bodyMedium,
              ),
            const SizedBox(height: 8),
            Text(
              '${t.printerProbe.selected}: '
              '${selected?.title ?? t.printerProbe.notSelected}',
              style: theme.textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}
