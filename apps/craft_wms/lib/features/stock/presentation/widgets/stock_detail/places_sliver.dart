import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../../core/constants/app_boxes.dart';
import '../../../../../core/constants/app_colors.dart';
import '../../../../../core/constants/app_insets.dart';
import '../../../../../core/constants/app_sizes.dart';
import '../../../../../core/gen/assets.gen.dart';
import '../../../../../core/gen/strings.g.dart';
import '../../../../../core/theme/regular_text.dart';
import '../../../../contents/presentation/widgets/common/freshness_note.dart';
import '../../bloc/stock_detail_cubit.dart';
import 'place_tile.dart';
import '../../../../../core/widgets/section_title.dart';

/// Секция «Наличие по местам хранения»: строки «ячейка · короб · партия · количество»,
/// подпись «данные на», если места из прежнего снимка (ADHOC-33), индикатор загрузки и «пусто».
///
/// **Возвращает sliver, а не обычный виджет.** Так индикатор и «пусто» получают
/// `SliverFillRemaining` - высоту незанятого остатка вьюпорта - и центрируются в нём.
/// Ребёнок обычного `ListView` этого не может: вьюпорт даёт детям неограниченную высоту
/// по оси прокрутки, и `Center` в такой ситуации сжимается по своему содержимому.
class PlacesSliver extends StatelessWidget {
  const PlacesSliver({super.key});

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
      case StockDetailStatus.loaded:
        // Пустой остаток - состояние на весь остаток экрана, как загрузка и ошибка:
        // элементом SliverList его отцентрировать нельзя (высота там неограниченная).
        if (state.items.isEmpty) {
          return SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (state.freshness case final f?)
                    FreshnessNote(freshness: f),
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
              // Первый элемент - заголовок секции, дальше строки остатка.
              childCount: state.items.length + 1,
            ),
          ),
        );
    }
  }

  /// Элемент списка секции: заголовок (с подписью свежести) или строка остатка.
  Widget _row(StockDetailState state, int i) {
    if (i == 0) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionTitle(title: t.stockDetailScreen.placesTitle),
          if (state.freshness case final f?) FreshnessNote(freshness: f),
        ],
      );
    }
    return Padding(
      padding: AppInsets.bottom8,
      child: PlaceTile(item: state.items[i - 1]),
    );
  }
}
