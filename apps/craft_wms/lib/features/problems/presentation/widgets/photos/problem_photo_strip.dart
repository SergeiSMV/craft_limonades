import 'dart:typed_data';

import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import '../../../../../core/constants/app_borders.dart';
import '../../../../../core/constants/app_boxes.dart';
import '../../../../../core/constants/app_colors.dart';
import '../../../../../core/constants/app_insets.dart';
import '../../../../../core/constants/app_sizes.dart';
import '../../../../../core/gen/strings.g.dart';
import '../../../../../core/theme/regular_text.dart';
import '../../../../../core/theme/semibold_text.dart';
import '../../../../../core/widgets/neumorphic_action_button.dart';
import '../../../domain/problem_photos.dart';
import '../../bloc/problem_photo_view.dart';

/// Фото проблемы склада (ADHOC-45): «Фото: N из 3», миниатюры и «Сфотографировать».
///
/// Миниатюра - выпуклая плашка, как карточка в форме; нажатие открывает снимок во весь экран.
/// [onAdd] `null` - снимать нельзя (проблема решена или уже три фото); [onRemove] `null` -
/// убирать нельзя (снимок уже на сервере или в очереди).
class ProblemPhotoStrip extends StatelessWidget {
  const ProblemPhotoStrip({
    super.key,
    required this.photos,
    this.onAdd,
    this.onRemove,
  });

  final List<ProblemPhotoView> photos;
  final VoidCallback? onAdd;
  final ValueChanged<String>? onRemove;

  /// Открыть снимок во весь экран.
  void open(BuildContext context, Uint8List content) => showDialog<void>(
    context: context,
    builder: (_) => Dialog(
      backgroundColor: AppColors.kNeumorphicBg,
      insetPadding: AppInsets.dialogInset,
      child: InteractiveViewer(child: Image.memory(content)),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final canAdd = onAdd != null && photos.length < kProblemPhotoMax;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          t.problems.photos(count: photos.length, max: kProblemPhotoMax),
          style: SemiboldTextStyles().semiboldInter14,
        ),
        if (photos.isNotEmpty) ...[
          AppBoxes.kHeight8,
          Wrap(
            spacing: AppSizes.kChipSpacing,
            runSpacing: AppSizes.kChipSpacing,
            children: [for (final p in photos) _thumb(context, p)],
          ),
        ],
        if (canAdd) ...[
          AppBoxes.kHeight8,
          NeumorphicActionButton(
            label: t.problems.takePhoto,
            icon: MdiIcons.camera,
            onPressed: onAdd!,
          ),
        ],
      ],
    );
  }

  /// Миниатюра: снимок, под ним - «Ждёт отправки» или «Убрать».
  Widget _thumb(BuildContext context, ProblemPhotoView p) {
    final content = p.content;
    final muted = RegularTextStyles().regularInter10.copyWith(
      color: AppColors.kTextMuted,
    );
    return SizedBox(
      width: AppSizes.kPhotoThumb,
      child: Column(
        children: [
          NeumorphicButton(
            onPressed: content == null ? null : () => open(context, content),
            padding: AppInsets.all4,
            style: NeumorphicStyle(
              shadowLightColor: AppColors.kNeumorphicLight,
              shadowDarkColor: AppColors.kNeumorphicDark,
              intensity: 1,
              color: AppColors.kNeumorphicBg,
              depth: 3,
              shape: NeumorphicShape.flat,
              boxShape: NeumorphicBoxShape.roundRect(AppBorders.kCircular8),
            ),
            child: ClipRRect(
              borderRadius: AppBorders.kCircular8,
              child: SizedBox.square(
                dimension: AppSizes.kPhotoThumb,
                child: content != null
                    ? Image.memory(content, fit: BoxFit.cover)
                    : Icon(
                        p.failed ? MdiIcons.imageOff : MdiIcons.imageOutline,
                        color: AppColors.kTextMuted,
                      ),
              ),
            ),
          ),
          if (p.pending) Text(t.problems.photoPending, style: muted),
          if (onRemove != null)
            TextButton(
              onPressed: () => onRemove!(p.id),
              child: Text(
                t.problems.photoRemove,
                style: RegularTextStyles().regularInter12.copyWith(
                  color: AppColors.kDanger,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
