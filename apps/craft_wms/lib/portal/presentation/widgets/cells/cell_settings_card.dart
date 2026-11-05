import 'package:flutter/material.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';
import '../../../domain/cells/cell_setup.dart';
import '../settings/access_common.dart';
import '../ui/portal_button.dart';
import '../ui/portal_card.dart';
import 'cell_label_sample.dart';
import 'cell_settings_options.dart';
import 'cells_controller.dart';

/// Карточка ячейки справа от списка (ADHOC-57): адрес и место, галочки этикетки на балку и
/// строки на карточке стеллажа, образец этикетки, «Отменить» и «Сохранить».
///
/// Отмечено несколько строк — карточка правит их разом: галочка у части выборки — с чертой.
/// Без права «Ячейки: изменять настройки» галочки только показываются.
class CellSettingsCard extends StatelessWidget {
  const CellSettingsCard({
    super.key,
    required this.c,
    required this.canEdit,
    required this.onSaved,
  });

  final CellsController c;
  final bool canEdit;

  /// Сохранено — текст для уведомления.
  final ValueChanged<String> onSaved;

  @override
  Widget build(BuildContext context) {
    final targets = c.targets;
    if (targets.isEmpty) return const PortalCard(children: [_Placeholder()]);
    return PortalCard(
      children: [
        Padding(
          padding: AppInsets.all16,
          child: CellSettingsHead(targets: targets),
        ),
        ...cellSettingsBlocks(c, targets, canEdit: canEdit),
        Padding(
          padding: AppInsets.cardRow,
          child: CellSettingsActions(c: c, canEdit: canEdit, onSaved: onSaved),
        ),
      ],
    );
  }
}

/// Разделы карточки под шапкой: галочки, образец (у одной ячейки) и ошибка сохранения.
List<Widget> cellSettingsBlocks(
  CellsController c,
  List<CellSetup> targets, {
  required bool canEdit,
}) => [
  BeamOptions(c: c, canEdit: canEdit),
  if (targets.length == 1) CellLabelSample(c: c, cell: targets.single),
  if (c.saveError != null)
    Padding(padding: AppInsets.cardRow, child: AccessError(c.saveError!)),
];

/// Шапка: у одной ячейки — адрес, стеллаж, ярус и позиция; у нескольких — сколько и стеллажи.
class CellSettingsHead extends StatelessWidget {
  const CellSettingsHead({super.key, required this.targets, this.title = true});

  final List<CellSetup> targets;

  /// Показывать заголовок: в окне он уже в шапке окна.
  final bool title;

  @override
  Widget build(BuildContext context) {
    final s = t.portal.cells.side;
    final one = targets.length == 1 ? targets.single : null;
    final facts = <(String, String)>[];
    if (one != null) {
      facts.add((s.rack, one.rackCode ?? t.portal.cells.noRack));
      if (one.tier != null) facts.add((s.tier, '${one.tier}'));
      if (one.position != null) facts.add((s.position, '${one.position}'));
    } else {
      final codes = <String>{
        for (final c in targets)
          if (c.rackCode != null) c.rackCode!,
      }.toList();
      const n = AppSizes.kCellsRackPreview;
      final list = codes.take(n).join(', ');
      if (codes.isNotEmpty) {
        facts.add((
          s.racks,
          codes.length > n
              ? s.racksMore(list: list, count: codes.length - n)
              : list,
        ));
      }
    }
    final muted = RegularTextStyles().regularInter13.copyWith(
      color: AppColors.kTextMuted,
    );
    final bold = SemiboldTextStyles().semiboldInter13.copyWith(
      color: AppColors.kTextMain,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title) ...[
          Text(
            one?.address ?? s.pickedTitle(count: targets.length),
            style: SemiboldTextStyles().semiboldInter16.copyWith(
              color: AppColors.kTextMain,
            ),
          ),
          AppBoxes.kHeight8,
        ],
        // Каждый факт своей подписанной строкой.
        for (final (label, value) in facts)
          Text.rich(
            TextSpan(
              text: '$label ',
              style: muted,
              children: [TextSpan(text: value, style: bold)],
            ),
          ),
      ],
    );
  }
}

/// «Отменить» и «Сохранить» с пометкой о несохранённом; без права — пометка «только просмотр».
class CellSettingsActions extends StatelessWidget {
  const CellSettingsActions({
    super.key,
    required this.c,
    required this.canEdit,
    required this.onSaved,
  });

  final CellsController c;
  final bool canEdit;
  final ValueChanged<String> onSaved;

  /// Сохранить; удалось — сообщить владельцу текст уведомления.
  Future<void> save() async {
    final text = await c.save();
    if (text != null) onSaved(text);
  }

  @override
  Widget build(BuildContext context) {
    final s = t.portal.cells.side;
    final dirty = c.draft.isNotEmpty;
    final note = !canEdit
        ? s.readOnly
        : dirty
        ? s.dirty
        : (c.targets.length > 1 ? s.mixedHint : '');
    return Row(
      children: [
        Expanded(
          child: Text(
            note,
            style: RegularTextStyles().regularInter12.copyWith(
              color: AppColors.kTextMuted,
            ),
          ),
        ),
        if (canEdit) ...[
          PortalButton(
            label: s.reset,
            kind: PortalButtonKind.plain,
            onPressed: dirty && !c.saving ? c.resetDraft : null,
          ),
          AppBoxes.kWidth8,
          PortalButton(
            label: s.save,
            kind: PortalButtonKind.primary,
            busy: c.saving,
            onPressed: dirty ? save : null,
          ),
        ],
      ],
    );
  }
}

/// Ничего не выбрано — подсказка, как выбрать.
class _Placeholder extends StatelessWidget {
  const _Placeholder();

  @override
  Widget build(BuildContext context) {
    final s = t.portal.cells.side;
    return Padding(
      padding: AppInsets.all24,
      child: Column(
        children: [
          const Icon(
            Icons.touch_app_outlined,
            size: AppSizes.kIcon30,
            color: AppColors.kInputBorder,
          ),
          AppBoxes.kHeight8,
          Text(
            s.placeholderTitle,
            style: SemiboldTextStyles().semiboldInter13.copyWith(
              color: AppColors.kTextMain,
            ),
          ),
          AppBoxes.kHeight4,
          Text(
            s.placeholder,
            textAlign: TextAlign.center,
            style: RegularTextStyles().regularInter13.copyWith(
              color: AppColors.kTextMuted,
            ),
          ),
        ],
      ),
    );
  }
}
