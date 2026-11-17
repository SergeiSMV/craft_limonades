import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart';

import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/problems/problem_reasons.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';
import '../../../../core/utils/date_time_format.dart';
import '../../../../core/warehouse/internal_warehouses.dart';
import '../../../../core/widgets/neumorphic_choice.dart';
import '../../../movement/presentation/widgets/move_format.dart'
    show withWarehouse;
import '../bloc/problem_state.dart';
import '../bloc/problem_photo_view.dart';
import 'photos/problem_photo_strip.dart';
import 'problem_format.dart';

/// Куда и почему: что помечаем (карточкой, как «В руках» в перемещении), склад назначения
/// и причина (вариантами, как фильтр «Остатков»), комментарий и - для «не нашей марки» -
/// марка (вдавленными полями, как диалог накладной).
class ProblemForm extends StatelessWidget {
  const ProblemForm({
    super.key,
    required this.state,
    required this.targets,
    required this.reasons,
    required this.comment,
    required this.mark,
    required this.onWarehouse,
    required this.onReason,
    required this.onTakePhoto,
    required this.onRemovePhoto,
  });

  final ProblemState state;
  final List<InternalWarehouse> targets;

  /// Причины на выбор - из справочника терминала (ADHOC-55).
  final List<ProblemReason> reasons;
  final TextEditingController comment;
  final TextEditingController mark;
  final ValueChanged<String> onWarehouse;
  final ValueChanged<ProblemReason> onReason;

  /// Снять фото к проблеме (ADHOC-45).
  final VoidCallback onTakePhoto;

  /// Убрать снимок до фиксации.
  final ValueChanged<String> onRemovePhoto;

  @override
  Widget build(BuildContext context) {
    final label = SemiboldTextStyles().semiboldInter14;
    return ListView(
      padding: AppInsets.h8,
      children: [
        _SubjectCard(subject: state.subject!),
        AppBoxes.kHeight16,
        Text(t.problems.toWarehouse, style: label),
        AppBoxes.kHeight8,
        if (targets.isEmpty)
          Text(
            t.problems.noWarehouses,
            style: RegularTextStyles().regularInter12.copyWith(
              color: AppColors.kTextMuted,
            ),
          )
        else
          _choices([
            for (final w in targets)
              NeumorphicChoice(
                label: w.name,
                selected: state.toWarehouseId == w.id,
                onPressed: () => onWarehouse(w.id),
              ),
          ]),
        AppBoxes.kHeight16,
        Text(t.problems.reason, style: label),
        AppBoxes.kHeight8,
        _choices([
          for (final r in reasons)
            NeumorphicChoice(
              label: r.name,
              selected: state.reason?.code == r.code,
              onPressed: () => onReason(r),
            ),
        ]),
        AppBoxes.kHeight16,
        _field(
          controller: comment,
          hint: state.reason?.commentRequired ?? false
              ? t.problems.commentRequired
              : t.problems.comment,
          multiline: true,
        ),
        if (state.reason?.code == ProblemReasonCodes.foreignMark) ...[
          AppBoxes.kHeight16,
          _field(controller: mark, hint: t.problems.mark),
        ],
        AppBoxes.kHeight16,
        // Фото - последним: снимают, когда остальное уже выбрано (ADHOC-45).
        ProblemPhotoStrip(
          photos: [
            for (final p in state.photos)
              ProblemPhotoView(id: p.id, content: p.content),
          ],
          onAdd: onTakePhoto,
          onRemove: onRemovePhoto,
        ),
        AppBoxes.kHeight16,
      ],
    );
  }

  /// Варианты - в строку с переносом.
  Widget _choices(List<Widget> items) => Wrap(
    spacing: AppSizes.kChipSpacing,
    runSpacing: AppSizes.kChipSpacing,
    children: items,
  );

  /// Вдавленное поле - как в окне накладной и количества.
  Widget _field({
    required TextEditingController controller,
    required String hint,
    bool multiline = false,
  }) => Neumorphic(
    style: NeumorphicStyle(
      shadowLightColor: AppColors.kNeumorphicLight,
      shadowDarkColor: AppColors.kNeumorphicDark,
      intensity: 1,
      color: AppColors.kNeumorphicBg,
      depth: -2,
      shape: NeumorphicShape.flat,
    ),
    child: TextField(
      controller: controller,
      cursorColor: AppColors.kTextMuted,
      minLines: 1,
      maxLines: multiline ? 3 : 1,
      style: RegularTextStyles().regularInter14,
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: RegularTextStyles().regularInter14.copyWith(
          color: AppColors.kBorderDashed,
        ),
        border: const OutlineInputBorder(
          borderRadius: AppBorders.kCircular8,
          borderSide: BorderSide.none,
        ),
      ),
    ),
  );
}

/// Что помечаем - построчно: наименование, партия, количество, место (короб - короб, позиции,
/// место).
class _SubjectCard extends StatelessWidget {
  const _SubjectCard({required this.subject});

  final ProblemSubject subject;

  @override
  Widget build(BuildContext context) {
    final muted = RegularTextStyles().regularInter12.copyWith(
      color: AppColors.kTextMuted,
    );
    final (title, lines) = switch (subject) {
      SubjectBox(:final box, :final cell) => (
        boxLabel(box),
        [
          t.problems.positionsLine(count: box.lines.length),
          t.problems.placeLine(place: cell.address),
        ],
      ),
      SubjectGoods(:final line, :final qty, :final cell, :final box) => (
        line.goodName ?? line.goodCode ?? '',
        [
          withWarehouse(
            t.problems.batchLine(date: batchDate(line.productionDate)),
            line.internalWarehouseName,
          ),
          t.problems.qtyLine(qty: qtyLabel(qty, line.uom)),
          t.problems.placeLine(place: placeLabel(cell, box)),
        ],
      ),
    };
    return Neumorphic(
      padding: AppInsets.all12,
      style: NeumorphicStyle(
        shadowLightColor: AppColors.kNeumorphicLight,
        shadowDarkColor: AppColors.kNeumorphicDark,
        intensity: 1,
        color: AppColors.kNeumorphicBg,
        depth: 3,
        boxShape: NeumorphicBoxShape.roundRect(AppBorders.kCircular8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: SemiboldTextStyles().semiboldInter14),
          for (final l in lines) Text(l, style: muted),
        ],
      ),
    );
  }
}
