import 'package:flutter/material.dart';

import '../../../../core/gen/strings.g.dart';
import '../ui/portal_modal.dart';
import 'cell_settings_card.dart';
import 'cells_controller.dart';

/// Карточка ячейки окном (ADHOC-57) — на узкой странице, где справа от списка ей нет места.
///
/// Как: окно слушает тот же [CellsController], что и страница: галочки, сохранение и
/// перечитывание видны и в окне, и в списке под ним. Сохранено — окно закрывается, текст
/// уходит в [onSaved].
Future<void> showCellSettingsSheet(
  BuildContext context,
  CellsController c, {
  required bool canEdit,
  required ValueChanged<String> onSaved,
}) => showDialog<void>(
  context: context,
  builder: (ctx) => ListenableBuilder(
    listenable: c,
    builder: (ctx, _) {
      final targets = c.targets;
      if (targets.isEmpty) return const SizedBox.shrink();
      return PortalModal(
        title: targets.length == 1
            ? targets.single.address
            : t.portal.cells.side.pickedSheet,
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            CellSettingsHead(targets: targets, title: false),
            ...cellSettingsBlocks(
              c,
              targets,
              canEdit: canEdit,
              onDone: onSaved,
            ),
          ],
        ),
        actions: [
          CellSettingsActions(
            c: c,
            canEdit: canEdit,
            onSaved: (text) {
              Navigator.of(ctx).pop();
              onSaved(text);
            },
          ),
        ],
      );
    },
  ),
);
