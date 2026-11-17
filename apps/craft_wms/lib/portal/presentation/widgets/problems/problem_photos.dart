import 'dart:typed_data';

import 'package:either_dart/either.dart';
import 'package:flutter/material.dart';

import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/error/failure.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../data/problems_repository.dart';

/// Фото проблемы со склада в карточке портала (ADHOC-45): миниатюры, по нажатию - снимок
/// целиком. Снимки грузятся по одному, когда карточку показали: список проблем от них не ждёт.
class ProblemPhotos extends StatefulWidget {
  const ProblemPhotos({
    super.key,
    required this.problemId,
    required this.photos,
  });

  final String problemId;
  final List<String> photos;

  @override
  State<ProblemPhotos> createState() => _ProblemPhotosState();
}

class _ProblemPhotosState extends State<ProblemPhotos> {
  final _repo = getIt<ProblemsRepository>();

  /// Загрузки - один раз на снимок, а не на каждую перерисовку.
  late final Map<String, Future<Either<Failure, Uint8List>>> _loads = {
    for (final id in widget.photos) id: _repo.photo(widget.problemId, id),
  };

  /// Открыть снимок целиком - в белом окне портала (ADHOC-56).
  void open(Uint8List content) => showDialog<void>(
    context: context,
    builder: (_) => Dialog(
      backgroundColor: AppColors.kCardBg,
      surfaceTintColor: Colors.transparent,
      insetPadding: AppInsets.dialogInset,
      shape: const RoundedRectangleBorder(borderRadius: AppBorders.kCircular12),
      clipBehavior: Clip.antiAlias,
      child: InteractiveViewer(child: Image.memory(content)),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AppSizes.kChipSpacing,
      runSpacing: AppSizes.kChipSpacing,
      children: [
        for (final id in widget.photos)
          FutureBuilder<Either<Failure, Uint8List>>(
            future: _loads[id],
            builder: (context, snap) => _thumb(snap.data),
          ),
      ],
    );
  }

  /// Миниатюра: снимок, пока грузится - ожидание, не загрузился - пометка.
  Widget _thumb(Either<Failure, Uint8List>? res) {
    final content = res != null && res.isRight ? res.right : null;
    final Widget child;
    if (content != null) {
      child = Image.memory(content, fit: BoxFit.cover);
    } else if (res == null) {
      child = const Center(child: CircularProgressIndicator(strokeWidth: 2));
    } else {
      child = Center(
        child: Text(
          t.portal.problems.photoFailed,
          textAlign: TextAlign.center,
          style: RegularTextStyles().regularInter12.copyWith(
            color: AppColors.kTextMuted,
          ),
        ),
      );
    }
    return InkWell(
      onTap: content == null ? null : () => open(content),
      borderRadius: AppBorders.kCircular8,
      child: ClipRRect(
        borderRadius: AppBorders.kCircular8,
        child: Container(
          width: AppSizes.kPhotoThumb,
          height: AppSizes.kPhotoThumb,
          color: AppColors.kBg,
          child: child,
        ),
      ),
    );
  }
}
