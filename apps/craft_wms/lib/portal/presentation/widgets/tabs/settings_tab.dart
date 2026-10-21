import 'package:flutter/material.dart';

import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../settings/warehouses_section.dart';

/// Вкладка «Настройки» (ADHOC-29): справочники, которые ведёт офис. Первый раздел — внутренние
/// склады; новые разделы встают сюда же, плашкой под предыдущей.
class SettingsTab extends StatelessWidget {
  const SettingsTab({super.key});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: AppInsets.all32,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: AppSizes.kContentMaxWidth,
          ),
          child: const WarehousesSection(),
        ),
      ),
    );
  }
}
