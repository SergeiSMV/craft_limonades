import 'package:flutter/material.dart';

import '../../../../../core/constants/app_sizes.dart';
import '../../../../../core/error/failure.dart';
import '../../../../../core/gen/strings.g.dart';
import '../../../../../core/widgets/error_retry.dart';
import '../../../domain/contents_entities.dart';
import '../../bloc/contents_view_state.dart';
import 'contents_message.dart';

/// Общая развилка экранов содержимого: загрузка, «показать нечего» и данные (P5-05).
///
/// «Нет связи» здесь — только когда и снимка нет: экран честно говорит, что делать
/// (обновить справочники при связи), а не предлагает бессмысленный повтор.
class ContentsStateView<T> extends StatelessWidget {
  const ContentsStateView({
    super.key,
    required this.state,
    required this.onRetry,
    required this.builder,
  });

  final ContentsViewState<T> state;
  final VoidCallback onRetry;

  /// Тело экрана по полученным данным.
  final Widget Function(Viewed<T> data) builder;

  @override
  Widget build(BuildContext context) {
    return switch (state) {
      ContentsViewLoading() => const Center(
        child: SizedBox(
          height: AppSizes.kIcon18,
          width: AppSizes.kIcon18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
      ContentsViewFailed(failure: NetworkFailure()) => ContentsMessage(
        text: t.contents.noConnection,
      ),
      ContentsViewFailed() => ErrorRetry(onRetry: onRetry),
      ContentsViewLoaded(:final data) => builder(data),
    };
  }
}
