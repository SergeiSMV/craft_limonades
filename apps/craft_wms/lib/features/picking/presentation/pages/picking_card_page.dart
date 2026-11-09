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
import '../../../../core/utils/doc_number.dart';
import '../../../../core/widgets/error_retry.dart';
import '../../../../core/widgets/neumorphic_line_tile.dart';
import '../../../../core/widgets/page_header.dart';
import '../../../../core/widgets/section_title.dart';
import '../../../../core/widgets/system_ui_wrapper.dart';
import '../../domain/picking_card.dart';
import '../bloc/picking_card_cubit.dart';
import '../widgets/picking_card_format.dart';

/// Карточка заказа сборки (ADHOC-62), только чтение: открывается из «Завершённых».
///
/// Сверху - шапка, кто собрал и отгрузил, итог; ниже - позиции план/факт по партиям с
/// «не хватает», короба с составом и журнал заказа. Касание позиции с марками - список марок.
@RoutePage()
class PickingCardPage extends StatelessWidget {
  const PickingCardPage({super.key, required this.orderId, this.number});

  final String orderId;

  /// Номер сборки для заголовка, пока заказ не загружен.
  final int? number;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => getIt<PickingCardCubit>(param1: orderId)..load(),
      child: _CardView(number: number),
    );
  }
}

class _CardView extends StatelessWidget {
  const _CardView({this.number});

  final int? number;

  static TextStyle get _muted =>
      RegularTextStyles().regularInter14.copyWith(color: AppColors.kTextMuted);

  /// Марки ЧЗ позиции нижним листом: в строке их может быть сотни.
  Future<void> showMarks(BuildContext context, PickingCardLine line) =>
      showModalBottomSheet<void>(
        backgroundColor: AppColors.kNeumorphicBg,
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (ctx) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            padding: AppInsets.h8,
            children: [
              SectionTitle(title: t.picking.cardMarksTitle),
              for (final m in line.marks) SelectableText(m, style: _muted),
              AppBoxes.kHeight16,
            ],
          ),
        ),
      );

  /// Касание позиции - её марки; у немаркируемой касание ничего не делает.
  void onLineTap(BuildContext context, PickingCardLine l) {
    if (l.marks.isNotEmpty) showMarks(context, l);
  }

  /// Короб в карточке только показывается: касание без действия.
  static void _noop() {}

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<PickingCardCubit, PickingCardState>(
      builder: (context, state) {
        final n = state.card?.number ?? number;
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
                title: n == null
                    ? t.picking.title
                    : docNumber(DocKind.picking, n),
                goBack: () => context.router.maybePop(),
              ),
            ),
            body: SafeArea(top: false, child: _body(context, state)),
          ),
        );
      },
    );
  }

  Widget _body(BuildContext context, PickingCardState state) {
    final c = state.card;
    if (state.status == PickingCardStatus.loading && c == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (c == null) {
      final f = state.failure;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: AppInsets.h8 + AppInsets.v16,
            child: Text(
              f is NetworkFailure
                  ? t.picking.cardOffline
                  : t.picking.cardFailed(
                      reason: f == null ? '' : failureReason(f),
                    ),
              style: _muted.copyWith(color: AppColors.kBadgeWarningText),
            ),
          ),
          Expanded(
            child: ErrorRetry(onRetry: context.read<PickingCardCubit>().load),
          ),
        ],
      );
    }
    final p = t.picking;
    return ListView(
      padding: AppInsets.h8 + AppInsets.v16,
      children: [
        for (final line in cardHeaderLines(c)) Text(line, style: _muted),
        SectionTitle(title: p.sectionLines),
        for (final l in c.items)
          Padding(
            padding: AppInsets.bottom8,
            child: Opacity(
              opacity: l.removed ? AppSizes.kInactiveOpacity : 1,
              child: NeumorphicLineTile(
                title: p.cardBoxGood(code: l.goodCode, name: l.goodName),
                subtitle: cardLineLines(l).join('\n'),
                note: cardLineNote(l),
                noteColor: AppColors.kBadgeCriticalText,
                onTap: () => onLineTap(context, l),
              ),
            ),
          ),
        SectionTitle(title: p.sectionBoxes),
        if (c.boxList.isEmpty) Text(p.cardNoBoxes, style: _muted),
        for (final b in c.boxList)
          Padding(
            padding: AppInsets.bottom8,
            child: NeumorphicLineTile(
              title: p.labelBox(seq: b.seq, count: c.boxList.length),
              subtitle: cardBoxLines(c, b).join('\n'),
              onTap: _noop,
            ),
          ),
        SectionTitle(title: p.sectionEvents),
        if (c.events.isEmpty) Text(p.cardNoEvents, style: _muted),
        for (final e in c.events) Text(cardEventLine(e), style: _muted),
      ],
    );
  }
}
