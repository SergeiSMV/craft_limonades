import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../../core/constants/app_boxes.dart';
import '../../../../../core/constants/app_colors.dart';
import '../../../../../core/constants/app_insets.dart';
import '../../../../../core/constants/app_sizes.dart';
import '../../../../../core/error/failure.dart';
import '../../../../../core/gen/strings.g.dart';
import '../../../../../core/theme/bold_text.dart';
import '../../../../../core/theme/regular_text.dart';
import '../../../../../core/utils/date_time_format.dart';
import '../../../../../core/widgets/detail_card.dart';
import '../../../../../core/widgets/section_title.dart';
import '../../../domain/contents_entities.dart';
import '../../bloc/load_unit_history_cubit.dart';
import '../common/contents_message.dart';

/// Блок «История» карточки короба (P5-05-1): приёмка и переносы. Только со связью — без неё
/// блок так и говорит, остальная карточка при этом из снимка.
class HistorySection extends StatelessWidget {
  const HistorySection({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<LoadUnitHistoryCubit>().state;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionTitle(title: t.contents.historyTitle),
        switch (state) {
          HistoryLoading() => const Padding(
            padding: AppInsets.all16,
            child: Center(
              child: SizedBox(
                width: AppSizes.kIcon18,
                height: AppSizes.kIcon18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ),
          HistoryFailed(failure: NetworkFailure()) => ContentsMessage(
            text: t.contents.historyOnlineOnly,
          ),
          HistoryFailed() => ContentsMessage(text: t.contents.historyFailed),
          HistoryLoaded(:final history) => _History(history: history),
        },
      ],
    );
  }
}

/// История по порядку: создание, приёмка, переносы.
class _History extends StatelessWidget {
  const _History({required this.history});

  final LoadUnitHistory history;

  @override
  Widget build(BuildContext context) {
    final receipt = history.receipt;
    return DetailCard(
      padding: AppInsets.all12,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _line(
            t.contents.historyCreated(time: fullDateTime(history.createdAt)),
          ),
          if (receipt != null) ...[
            _muted(t.contents.historyReceived(name: receipt.receivedBy)),
            _muted(
              receipt.supplier == null
                  ? t.contents.historyNoSupplier
                  : t.contents.historySupplier(name: receipt.supplier!),
            ),
            if (receipt.postedAt == null) _muted(t.contents.historyNotPosted),
          ],
          for (final m in history.moves) ...[
            AppBoxes.kHeight8,
            _line(
              m.byReceipt || m.from == null
                  ? t.contents.moveReceipt(to: m.to)
                  : t.contents.movePutaway(from: m.from!, to: m.to),
            ),
            _muted(
              m.userName == null
                  ? t.contents.moveByUnknown(time: fullDateTime(m.at))
                  : t.contents.moveBy(
                      name: m.userName!,
                      time: fullDateTime(m.at),
                    ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _line(String text) => Text(
    text,
    style: BoldTextStyles().boldInter14.copyWith(
      color: AppColors.kSidebarHover,
    ),
  );

  Widget _muted(String text) => Text(
    text,
    style: RegularTextStyles().regularInter12.copyWith(
      color: AppColors.kTextMuted,
    ),
  );
}
