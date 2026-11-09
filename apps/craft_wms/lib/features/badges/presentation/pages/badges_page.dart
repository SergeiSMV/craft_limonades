import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/error/failure.dart';
import '../../../../core/error/failure_reason.dart';
import '../../../../core/gen/assets.gen.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/widgets/error_retry.dart';
import '../../../../core/widgets/neumorphic_line_tile.dart';
import '../../../../core/widgets/page_header.dart';
import '../../../../core/widgets/system_ui_wrapper.dart';
import '../../domain/badge_holder.dart';
import '../bloc/badges_cubit.dart';

/// «Бейджи» (ADHOC-65): печать бейджей сотрудников на мобильный принтер.
///
/// Список - кого пользователь вправе печатать (свой; всех, кроме администратора; всех), его
/// составляет сервер. Касание сотрудника - бейдж на принтер. Только со связью: номер бейджа
/// выдаёт сервер.
@RoutePage()
class BadgesPage extends StatelessWidget {
  const BadgesPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => getIt<BadgesCubit>()..load(),
      child: const _BadgesView(),
    );
  }
}

class _BadgesView extends StatelessWidget {
  const _BadgesView();

  static TextStyle get _muted =>
      RegularTextStyles().regularInter14.copyWith(color: AppColors.kTextMuted);

  void _snack(BuildContext context, String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  /// Подсказки по итогу печати - один раз.
  void onNotice(BuildContext context, BadgesState state) {
    final n = state.notice;
    if (n == null) return;
    context.read<BadgesCubit>().clearNotice();
    final b = t.badges;
    _snack(context, switch (n) {
      BadgesNoticeFetchFailed(:final failure) =>
        failure is NetworkFailure
            ? b.fetchOffline
            : b.fetchFailed(reason: failureReason(failure)),
      BadgesNoticePrinted(:final fullName) => b.printed(name: fullName),
      BadgesNoticePrintFailed(:final reason) => b.printFailed(reason: reason),
    });
  }

  /// Подпись должности на бейдже и в списке.
  static String positionLine(BadgeHolder h) =>
      t.badges.position(name: h.isAdmin ? t.badges.admin : h.positionName);

  /// Касание сотрудника - печать; номера нет - объяснение вместо запроса.
  void onTap(BuildContext context, BadgesState state, BadgeHolder h) {
    if (state.busy) return;
    if (!h.stored) {
      _snack(context, t.badges.notStored);
      return;
    }
    _snack(context, t.badges.printing);
    context.read<BadgesCubit>().printBadge(h, position: positionLine(h));
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<BadgesCubit, BadgesState>(
      listenWhen: (a, b) => b.notice != null && a.notice != b.notice,
      listener: onNotice,
      builder: (context, state) => SystemUiWrapper(
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
              title: t.badges.title,
              goBack: () => context.router.maybePop(),
            ),
          ),
          body: SafeArea(top: false, child: _body(context, state)),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, BadgesState state) {
    if (state.status == BadgesStatus.loading && state.holders.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.status == BadgesStatus.error) {
      final f = state.failure;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: AppInsets.h8 + AppInsets.v16,
            child: Text(
              f is NetworkFailure
                  ? t.badges.offline
                  : t.badges.failed(reason: f == null ? '' : failureReason(f)),
              style: _muted.copyWith(color: AppColors.kBadgeWarningText),
            ),
          ),
          Expanded(
            child: ErrorRetry(onRetry: context.read<BadgesCubit>().load),
          ),
        ],
      );
    }
    if (state.holders.isEmpty) {
      return Padding(
        padding: AppInsets.h8 + AppInsets.v16,
        child: Text(t.badges.empty, style: _muted),
      );
    }
    return ListView(
      padding: AppInsets.h8 + AppInsets.v16,
      children: [
        Text(t.badges.hint, style: _muted),
        AppBoxes.kHeight8,
        for (final h in state.holders)
          Padding(
            padding: AppInsets.bottom8,
            child: NeumorphicLineTile(
              title: h.fullName,
              subtitle: positionLine(h),
              note: h.stored ? null : t.badges.notStored,
              noteColor: AppColors.kBadgeWarningText,
              onTap: () => onTap(context, state, h),
            ),
          ),
      ],
    );
  }
}
