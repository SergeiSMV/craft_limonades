import 'package:flutter/material.dart';

import '../../../../../core/constants/app_boxes.dart';
import '../../../../../core/constants/app_insets.dart';
import '../../../data/catalog_models.dart';
import 'barcodes_section.dart';
import 'good_info_card.dart';
import 'places_sliver.dart';
import 'total_bar.dart';

/// Тело карточки остатков: прокручиваемая часть (шапка товара, штрихкоды, места хранения)
/// и закреплённая снизу панель итога.
///
/// Собрано на `CustomScrollView`, а не на `ListView`, ради последней секции: только sliver
/// знает незанятый остаток вьюпорта, поэтому индикатор загрузки и блок ошибки могут
/// центрироваться в нём (см. [PlacesSliver]).
class StockDetailBody extends StatelessWidget {
  const StockDetailBody({super.key, required this.good});

  /// Товар, чьи остатки открыты.
  final Good good;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: CustomScrollView(
            physics: const BouncingScrollPhysics(),
            slivers: [
              SliverPadding(
                padding: AppInsets.h8,
                sliver: SliverToBoxAdapter(child: GoodInfoCard(good: good)),
              ),
              const SliverToBoxAdapter(child: AppBoxes.kHeight8),
              SliverPadding(
                padding: AppInsets.h8,
                sliver: SliverToBoxAdapter(
                  child: BarcodesSection(goodName: good.name),
                ),
              ),
              PlacesSliver(goodId: good.id),
            ],
          ),
        ),
        const TotalBar(),
      ],
    );
  }
}
