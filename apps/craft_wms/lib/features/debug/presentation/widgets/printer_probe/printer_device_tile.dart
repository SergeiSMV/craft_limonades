import 'package:flutter/material.dart';

import '../../../../../core/printer/printer_device.dart';

/// Строка списка устройств: имя (или адрес, если имени нет) и MAC-адрес.
///
/// Выбранное устройство помечено галкой: на складе принтеров может оказаться несколько
/// (чужие терминалы рядом), и без пометки непонятно, в какой из них уйдёт печать.
class PrinterDeviceTile extends StatelessWidget {
  const PrinterDeviceTile({
    required this.device,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final PrinterDevice device;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      leading: Icon(selected ? Icons.check_circle : Icons.print_outlined),
      title: Text(device.title),
      subtitle: Text(device.address),
      onTap: onTap,
    );
  }
}
