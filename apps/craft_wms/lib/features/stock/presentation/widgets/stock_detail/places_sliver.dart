import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../../core/constants/app_boxes.dart';
import '../../../../../core/constants/app_colors.dart';
import '../../../../../core/constants/app_insets.dart';
import '../../../../../core/constants/app_sizes.dart';
import '../../../../../core/gen/assets.gen.dart';
import '../../../../../core/gen/strings.g.dart';
import '../../../../../core/theme/regular_text.dart';
import '../../bloc/stock_detail_cubit.dart';
import '../../../../../core/widgets/error_retry.dart';
import 'place_tile.dart';
import '../../../../../core/widgets/section_title.dart';

/// Секция «Наличие по местам хранения»: строки «ячейка · партия · количество»,
/// а также индикатор загрузки, ошибка с повтором и «пусто».
/// Всё показывается россыпью — разбивка по грузовым единицам (ГЕ) появится в P4/P5.
///
/// **Возвращает sliver, а не обычный виджет.** Так индикатор и блок ошибки получают
/// `SliverFillRemaining` — высоту незанятого остатка вьюпорта — и центрируются в нём.
/// Ребёнок обычного `ListView` этого не может: вьюпорт даёт детям неограниченную высоту
/// по оси прокрутки, и `Center` в такой ситуации сжимается по своему содержимому.
class PlacesSliver extends StatelessWidget {
  const PlacesSliver({super.key, required this.goodId});

  /// Товар, чьи остатки грузим (нужен для повтора после ошибки).
  final String goodId;

  /// Повторить загрузку карточки после ошибки.
  void retryLoad(BuildContext context) =>
      context.read<StockDetailCubit>().load(goodId);

  @override
  Widget build(BuildContext context) {
    final state = context.watch<StockDetailCubit>().state;

    switch (state.status) {
      case StockDetailStatus.loading:
        return const SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: SizedBox(
              height: AppSizes.kIcon18,
              width: AppSizes.kIcon18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        );
      case StockDetailStatus.error:
        // ErrorRetry сам центрирует содержимое, второй Center не нужен.
        return SliverFillRemaining(
          hasScrollBody: false,
          child: ErrorRetry(onRetry: () => retryLoad(context)),
        );
      case StockDetailStatus.loaded:
        // Пустой остаток — состояние на весь остаток экрана, как загрузка и ошибка:
        // элементом SliverList его отцентрировать нельзя (высота там неограниченная).
        if (state.items.isEmpty) {
          return SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Assets.icons.goodsNotFound.image(width: AppSizes.kIcon90),
                  AppBoxes.kHeight12,
                  Text(
                    t.stockDetailScreen.empty,
                    style: RegularTextStyles().regularInter14.copyWith(
                      color: AppColors.kTextMuted,
                    ),
                  ),
                ],
              ),
            ),
          );
        }
        return SliverPadding(
          padding: AppInsets.h8 + AppInsets.bottom8,
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, i) => _row(state, i),
              // Первый элемент — заголовок секции, дальше строки остатка.
              childCount: state.items.length + 1,
            ),
          ),
        );
    }
  }

  /// Элемент списка секции: заголовок или строка остатка.
  Widget _row(StockDetailState state, int i) {
    if (i == 0) return SectionTitle(title: t.stockDetailScreen.placesTitle);
    return Padding(
      padding: AppInsets.bottom8,
      child: PlaceTile(item: state.items[i - 1]),
    );
  }
}
