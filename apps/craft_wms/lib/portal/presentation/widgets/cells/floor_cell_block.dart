import 'package:flutter/material.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';
import '../../../domain/cells/cell_setup.dart';
import '../ui/portal_button.dart';
import 'cells_controller.dart';
import 'floor_cell_dialogs.dart';

/// Раздел «Напольное хранение» карточки одной напольной ячейки (ADHOC-61): что это за ячейка и
/// что на её этикетке, «Изменить адрес» и «Удалить».
///
/// Действия — только с правом «Ячейки: изменять настройки». Ответ сервера (успех или причина
/// отказа: адрес занят, в ячейке товар) уходит в [onDone] уведомлением.
class FloorCellBlock extends StatelessWidget {
  const FloorCellBlock({
    super.key,
    required this.c,
    required this.cell,
    required this.canEdit,
    required this.onDone,
  });

  final CellsController c;
  final CellSetup cell;
  final bool canEdit;
  final ValueChanged<String> onDone;

  Future<void> rename(BuildContext context) async {
    final address = await showFloorCellAddressDialog(
      context,
      current: cell.address,
    );
    if (address == null || address == cell.address) return;
    onDone(await c.renameFloorCell(cell.id, address));
  }

  Future<void> delete(BuildContext context) async {
    if (!await showDeleteFloorCellDialog(context, address: cell.address)) {
      return;
    }
    onDone(await c.deleteFloorCell(cell));
  }

  @override
  Widget build(BuildContext context) {
    final s = t.portal.cells.floor;
    return Padding(
      padding: AppInsets.cardRow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            s.title,
            style: SemiboldTextStyles().semiboldInter13.copyWith(
              color: AppColors.kTextMain,
            ),
          ),
          AppBoxes.kHeight4,
          Text(
            s.hint,
            style: RegularTextStyles().regularInter12.copyWith(
              color: AppColors.kTextMuted,
            ),
          ),
          if (canEdit) ...[
            AppBoxes.kHeight8,
            Wrap(
              spacing: AppSizes.kChipSpacing,
              runSpacing: AppSizes.kChipSpacing,
              children: [
                PortalButton(
                  label: s.rename,
                  icon: Icons.edit_outlined,
                  onPressed: () => rename(context),
                ),
                PortalButton(
                  label: s.delete,
                  icon: Icons.delete_outline,
                  onPressed: () => delete(context),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
