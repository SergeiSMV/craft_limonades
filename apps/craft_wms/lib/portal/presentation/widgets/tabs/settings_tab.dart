import 'package:flutter/material.dart';

import '../../../../core/auth/profile.dart';
import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../settings/positions_section.dart';
import '../settings/users_section.dart';
import '../settings/warehouses_section.dart';

/// Вкладка «Настройки» (ADHOC-29): справочники, которые ведёт офис. Разделы — по правам
/// (ADHOC-50): внутренние склады — право «внутренние склады», должности и пользователи —
/// право «пользователи и должности»; новые разделы встают сюда же, плашкой под предыдущей.
class SettingsTab extends StatefulWidget {
  const SettingsTab({
    super.key,
    required this.warehouses,
    required this.users,
    required this.profile,
  });

  /// Показать «Внутренние склады».
  final bool warehouses;

  /// Показать «Должности» и «Пользователи».
  final bool users;

  /// Вошедший оператор — себя в списке пользователей не заблокировать.
  final Profile profile;

  @override
  State<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<SettingsTab> {
  /// Счётчик правок должностей и пользователей: разделы перечитывают друг друга.
  final _accessChanges = ValueNotifier<int>(0);

  @override
  void dispose() {
    _accessChanges.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: AppInsets.all32,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: AppSizes.kContentMaxWidth,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.warehouses) const WarehousesSection(),
              if (widget.users) ...[
                if (widget.warehouses) AppBoxes.kHeight24,
                PositionsSection(changes: _accessChanges),
                AppBoxes.kHeight24,
                UsersSection(
                  changes: _accessChanges,
                  selfId: widget.profile.userId,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
