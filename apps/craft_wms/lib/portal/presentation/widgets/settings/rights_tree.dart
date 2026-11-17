import 'package:flutter/material.dart';

import '../../../../core/auth/rights.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';

/// Дерево прав с галочками (ADHOC-50): приложение → раздел → действия.
///
/// Галочка группы ставит или снимает все действия внутри; отмечена часть - «полугалочка».
/// Приложения раскрыты, разделы свёрнуты - раскрываются стрелкой или касанием названия:
/// состояние раздела видно по его галочке и без раскрытия.
class RightsTree extends StatefulWidget {
  const RightsTree({
    super.key,
    required this.selected,
    required this.onChanged,
  });

  /// Отмеченные действия.
  final Set<String> selected;

  /// Новый набор отмеченных действий.
  final ValueChanged<Set<String>> onChanged;

  @override
  State<RightsTree> createState() => _RightsTreeState();
}

class _RightsTreeState extends State<RightsTree> {
  final _tree = rightsTree();

  /// Раскрытые группы - по пути из названий; приложения раскрыты сразу.
  late final Set<String> _open = {for (final app in _tree) app.label};

  /// Раскрыть или свернуть группу.
  void toggleOpen(String path) => setState(
    () => _open.contains(path) ? _open.remove(path) : _open.add(path),
  );

  /// Галочка узла: все действия отмечены - снять их, иначе - отметить все.
  void toggle(RightNode node) {
    final codes = node.codes;
    final all = codes.every(widget.selected.contains);
    widget.onChanged(
      all
          ? (widget.selected.difference(codes.toSet()))
          : (widget.selected.union(codes.toSet())),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    void add(RightNode node, int depth, String path) {
      rows.add(_row(node, depth, path));
      if (node.children.isNotEmpty && _open.contains(path)) {
        for (final c in node.children) {
          add(c, depth + 1, '$path/${c.label}');
        }
      }
    }

    for (final app in _tree) {
      add(app, 0, app.label);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: rows,
    );
  }

  Widget _row(RightNode node, int depth, String path) {
    final codes = node.codes;
    final count = codes.where(widget.selected.contains).length;
    final value = count == 0 ? false : (count == codes.length ? true : null);
    final group = node.children.isNotEmpty;
    final open = _open.contains(path);
    final style = group
        ? SemiboldTextStyles().semiboldInter14
        : RegularTextStyles().regularInter14;
    return Padding(
      padding: EdgeInsets.only(left: AppSizes.kPortalTreeIndent * depth),
      child: Row(
        children: [
          Checkbox(
            value: value,
            tristate: true,
            activeColor: AppColors.kButtonPrimary,
            onChanged: (_) => toggle(node),
          ),
          Expanded(
            child: InkWell(
              onTap: group ? () => toggleOpen(path) : () => toggle(node),
              child: Padding(
                padding: AppInsets.v8,
                child: Text(
                  node.label,
                  style: style.copyWith(color: AppColors.kTextMain),
                ),
              ),
            ),
          ),
          if (group && depth > 0)
            IconButton(
              icon: Icon(
                open ? Icons.expand_less : Icons.expand_more,
                size: AppSizes.kIcon20,
                color: AppColors.kTextMuted,
              ),
              onPressed: () => toggleOpen(path),
            ),
        ],
      ),
    );
  }
}

/// Сводка прав для строки должности: по приложению - разделы, где есть хоть одно действие,
/// например «Портал: Приход, Проблемы склада».
List<String> rightsSummary(List<String> rights) => [
  for (final app in rightsTree())
    if (app.codes.any(rights.contains))
      '${app.label}: ${[for (final section in app.children)
        if (section.codes.any(rights.contains)) section.label].join(', ')}',
];
