import 'package:flutter/material.dart';

import '../../../../core/auth/profile.dart';
import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/gen/strings.g.dart';
import '../settings/positions_section.dart';
import '../settings/problem_reasons_section.dart';
import '../settings/users_section.dart';
import '../settings/warehouses_section.dart';
import '../shell/sidebar_menu_item.dart';
import '../ui/portal_choice.dart';

/// Группа разделов настроек: пункт навигации и что в нём.
typedef _SettingsGroup = ({IconData icon, String label, WidgetBuilder body});

/// Вкладка «Настройки» (ADHOC-29): справочники, которые ведёт офис. Разделы — по правам
/// (ADHOC-50): внутренние склады — право «внутренние склады», причины проблем и варианты
/// решения — право «причины проблем» (ADHOC-55), должности и пользователи — право
/// «пользователи и должности».
///
/// Вид — шаблон настроек Shopify Polaris (ADHOC-56): разделы собраны в группы («Склады»,
/// «Проблемы склада», «Доступ»), на экране — одна группа. Раскладка — по ширине, которая
/// досталась вкладке: от [AppSizes.kSettingsNavWidth] группы списком слева, уже — вариантами
/// выбора сверху; одна группа — без выбора. Новый справочник встаёт разделом в свою группу.
class SettingsTab extends StatefulWidget {
  const SettingsTab({
    super.key,
    required this.warehouses,
    this.problemReasons = false,
    required this.users,
    required this.profile,
  });

  /// Показать «Внутренние склады».
  final bool warehouses;

  /// Показать «Причины проблем» и «Варианты решения».
  final bool problemReasons;

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

  int _selected = 0;

  @override
  void dispose() {
    _accessChanges.dispose();
    super.dispose();
  }

  /// Группы, на которые у оператора есть права.
  List<_SettingsGroup> get _groups {
    final tr = t.portal.settings;
    return [
      if (widget.warehouses)
        (
          icon: Icons.warehouse_outlined,
          label: tr.groupWarehouses,
          body: (_) => const WarehousesSection(),
        ),
      if (widget.problemReasons)
        (
          icon: Icons.report_problem_outlined,
          label: tr.groupProblems,
          body: (_) => const ProblemReasonsSection(),
        ),
      if (widget.users)
        (
          icon: Icons.group_outlined,
          label: tr.groupAccess,
          body: (_) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PositionsSection(changes: _accessChanges),
              AppBoxes.kHeight32,
              UsersSection(
                changes: _accessChanges,
                selfId: widget.profile.userId,
              ),
            ],
          ),
        ),
    ];
  }

  /// Открыть группу.
  void select(int index) => setState(() => _selected = index);

  @override
  Widget build(BuildContext context) {
    final groups = _groups;
    if (groups.isEmpty) return const SizedBox.shrink();
    final selected = _selected.clamp(0, groups.length - 1);
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= AppSizes.kSettingsNavWidth;
        final narrow = constraints.maxWidth < AppSizes.kPortalCompactWidth;
        // Ключ по группе: разделы новой группы загружаются заново, а не берут чужое состояние.
        final body = KeyedSubtree(
          key: ValueKey(groups[selected].label),
          child: Builder(builder: groups[selected].body),
        );
        final Widget content;
        if (groups.length == 1) {
          content = body;
        } else if (wide) {
          content = Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: AppSizes.kSettingsNavColumn,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < groups.length; i++)
                      SidebarMenuItem(
                        icon: groups[i].icon,
                        label: groups[i].label,
                        active: i == selected,
                        onTap: () => select(i),
                      ),
                  ],
                ),
              ),
              AppBoxes.kWidth24,
              Expanded(child: body),
            ],
          );
        } else {
          content = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: AppSizes.kChipSpacing,
                runSpacing: AppSizes.kChipSpacing,
                children: [
                  for (var i = 0; i < groups.length; i++)
                    PortalChoice(
                      label: groups[i].label,
                      selected: i == selected,
                      onTap: () => select(i),
                    ),
                ],
              ),
              AppBoxes.kHeight24,
              body,
            ],
          );
        }
        return SingleChildScrollView(
          padding: narrow ? AppInsets.pageCompact : AppInsets.page,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: AppSizes.kSettingsMaxWidth,
              ),
              child: content,
            ),
          ),
        );
      },
    );
  }
}
