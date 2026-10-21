import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/error/failure.dart';
import '../../../../core/gen/assets.gen.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/utils/date_time_format.dart';
import '../../../../core/widgets/page_header.dart';
import '../../../../core/widgets/system_ui_wrapper.dart';
import '../../../tasks/presentation/widgets/common/tasks_message.dart';
import '../bloc/movement_record_cubit.dart';
import '../widgets/history/move_record_tile.dart';
import '../widgets/move_lines_list.dart';

/// Запись истории перемещений (ADHOC-28): кто и когда перемещал и что — откуда и куда, по
/// порядку проведения, с коробами и перекладыванием внутри ячейки. Только онлайн.
@RoutePage()
class MovementRecordPage extends StatelessWidget {
  const MovementRecordPage({super.key, required this.movementId});

  final String movementId;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => getIt<MovementRecordCubit>()..load(movementId),
      child: _MovementRecordView(movementId: movementId),
    );
  }
}

class _MovementRecordView extends StatelessWidget {
  const _MovementRecordView({required this.movementId});

  final String movementId;

  /// Вернуться к ленте.
  void goBack(BuildContext context) => context.router.maybePop();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<MovementRecordCubit>().state;
    return SystemUiWrapper(
      style: StatusBarStyle.light,
      child: Scaffold(
        backgroundColor: AppColors.kNeumorphicBg,
        // Шапка — как у раздела «Перемещение»: фон-картинка и заголовок с возвратом.
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
            title: state is RecordLoaded
                ? moveKindLabel(state.detail.record.kind)
                : t.movement.title,
            goBack: () => goBack(context),
          ),
        ),
        body: SafeArea(top: false, child: _body(context, state)),
      ),
    );
  }

  Widget _body(BuildContext context, MovementRecordState state) {
    switch (state) {
      case RecordLoading():
        return const Center(child: CircularProgressIndicator());
      case RecordFailed(:final failure):
        return TasksMessage(
          text: failure is NetworkFailure
              ? t.movement.historyOnlineOnly
              : t.movement.historyLoadFailed,
          showImage: true,
          onRetry: () => context.read<MovementRecordCubit>().load(movementId),
        );
      case RecordLoaded(:final detail):
        final r = detail.record;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: AppInsets.h8 + AppInsets.v16,
              child: Text(
                t.movement.recordMeta(
                  name: r.executor.fullName,
                  time: fullDateTime(r.postedAtTime),
                ),
                style: RegularTextStyles().regularInter14.copyWith(
                  color: AppColors.kTextMuted,
                ),
              ),
            ),
            Expanded(
              child: MoveLinesList(
                lines: detail.lines,
                title: t.movement.recordLines,
                newestFirst: false,
              ),
            ),
          ],
        );
    }
  }
}
