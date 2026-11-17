import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/gen/assets.gen.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';
import '../../../../core/utils/date_time_format.dart';
import '../../../../core/widgets/detail_card.dart';
import '../../../../core/widgets/page_header.dart';
import '../../../../core/widgets/section_title.dart';
import '../../../../core/widgets/system_ui_wrapper.dart';
import '../../domain/problem_records.dart';
import '../bloc/record_photos_cubit.dart';
import '../widgets/photos/problem_photo_strip.dart';
import '../widgets/records/record_format.dart';

/// Карточка проблемы (ADHOC-34, ADHOC-35) - тремя разделами по порядку событий: проблема (что,
/// где, склад WMS, причина, кто зафиксировал), решение офиса (что решили, кому вернуть, кто
/// решил) и исполнение (списано по документу 1С, размещено, отгружено - кто и когда). Всё
/// пришло в списке, поэтому карточка открывается без запроса и без связи. У открытой -
/// проблема и «Ждёт решения офиса» (или «Ожидает отправки» у своей неотправленной).
@RoutePage()
class ProblemRecordPage extends StatelessWidget {
  const ProblemRecordPage({super.key, required this.problem});

  final ProblemRecord problem;

  /// Вернуться к ленте.
  void goBack(BuildContext context) => context.router.maybePop();

  @override
  Widget build(BuildContext context) {
    final p = problem;
    final executed = executedMeta(p);
    return SystemUiWrapper(
      style: StatusBarStyle.light,
      child: Scaffold(
        backgroundColor: AppColors.kNeumorphicBg,
        appBar: AppBar(
          automaticallyImplyLeading: false,
          backgroundColor: Colors.transparent,
          elevation: 0,
          toolbarHeight: AppSizes.kIcon60,
          flexibleSpace: ClipRRect(
            borderRadius: AppBorders.kBottom10,
            child: Assets.images.featuredSnacks.image(fit: BoxFit.cover),
          ),
          title: PageHeader(
            title: t.problems.title,
            goBack: () => goBack(context),
          ),
        ),
        body: SafeArea(
          top: false,
          child: ListView(
            padding: AppInsets.h8 + AppInsets.v16,
            children: [
              SectionTitle(title: t.problems.sectionProblem),
              _card([
                _muted(numberLabel(p)),
                _strong(subjectLabel(p)),
                for (final line in subjectLines(p)) _text(line),
                // У пересорта (ADHOC-53) ячейки и складов нет: он лежит, где лежал.
                if (p.cellAddress.isNotEmpty)
                  _text(t.problems.placeLine(place: p.cellAddress)),
                if (p.fromWarehouse.isNotEmpty)
                  _text(
                    t.problems.warehousesLine(
                      from: p.fromWarehouse,
                      to: p.toWarehouse,
                    ),
                  ),
                _text(t.problems.reasonLine(reason: reasonText(p))),
                if (p.comment.isNotEmpty)
                  _text(t.problems.commentLine(comment: p.comment)),
                if (p.mark != null) _text(t.problems.markLine(mark: p.mark!)),
                _muted(createdMeta(p)),
              ]),
              AppBoxes.kHeight8,
              // Фото (ADHOC-45): с сервера, свои неотправленные, у открытой - снять ещё.
              BlocProvider(
                create: (_) => getIt<RecordPhotosCubit>()..load(p),
                child: const _RecordPhotos(),
              ),
              AppBoxes.kHeight8,
              SectionTitle(title: t.problems.sectionDecision),
              // Открытая - решения ещё нет, и исполнять нечего: раздел исполнения не нужен.
              if (p.isOpen)
                _card([_strong(outcomeLabel(p))])
              else ...[
                _card([
                  _strong(resolutionText(p)),
                  for (final line in decisionLines(p)) _text(line),
                  _muted(
                    t.problems.resolvedMeta(
                      name: p.resolvedBy,
                      time: fullDateTime(p.resolvedAtTime),
                    ),
                  ),
                ]),
                AppBoxes.kHeight8,
                SectionTitle(title: t.problems.sectionExecution),
                _card([
                  _strong(outcomeLabel(p)),
                  for (final line in executionLines(p)) _text(line),
                  if (executed != null) _muted(executed),
                ]),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _card(List<Widget> lines) => DetailCard(
    padding: AppInsets.all12,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: lines,
    ),
  );

  Widget _strong(String text) => Text(
    text,
    style: SemiboldTextStyles().semiboldInter16.copyWith(
      color: AppColors.kSidebarHover,
    ),
  );

  Widget _text(String text) => Text(
    text,
    style: RegularTextStyles().regularInter14.copyWith(
      color: AppColors.kTextMain,
    ),
  );

  Widget _muted(String text) => Padding(
    padding: AppInsets.top4,
    child: Text(
      text,
      style: RegularTextStyles().regularInter12.copyWith(
        color: AppColors.kTextMuted,
      ),
    ),
  );
}

/// Фото в карточке - плашкой, как остальные разделы.
class _RecordPhotos extends StatelessWidget {
  const _RecordPhotos();

  /// Снять фото к проблеме.
  void take(BuildContext context) => context.read<RecordPhotosCubit>().take();

  @override
  Widget build(BuildContext context) {
    final cubit = context.watch<RecordPhotosCubit>();
    return DetailCard(
      padding: AppInsets.all12,
      child: ProblemPhotoStrip(
        photos: cubit.state,
        onAdd: cubit.canAdd ? () => take(context) : null,
      ),
    );
  }
}
