import 'package:flutter/material.dart';

import '../../../../../core/constants/app_boxes.dart';
import '../../../../../core/constants/app_insets.dart';
import '../../../../cz/domain/cz_scan.dart';
import '../../../../cz/presentation/widgets/cz_mark_section.dart';
import '../../../../cz/presentation/widgets/cz_marked_section.dart';
import '../../../domain/catalog_models.dart';
import 'barcodes_section.dart';
import 'good_info_card.dart';
import 'places_sliver.dart';
import 'unbound_barcode_notice.dart';
import 'total_bar.dart';

/// Тело карточки остатков: прокручиваемая часть (шапка товара, штрихкоды, места хранения)
/// и закреплённая снизу панель итога.
///
/// Собрано на `CustomScrollView`, а не на `ListView`, ради последней секции: только sliver
/// знает незанятый остаток вьюпорта, поэтому индикатор загрузки и блок ошибки могут
/// центрироваться в нём (см. [PlacesSliver]).
class StockDetailBody extends StatelessWidget {
  const StockDetailBody({super.key, required this.good, this.czMark});

  /// Товар, чьи остатки открыты.
  final Good good;

  /// Скан марки «Честного знака», которым открыта карточка (CZ-04); `null` - обычная карточка.
  final CzScanResult? czMark;

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
              // Маркируемый ли товар (CZ-05): видят все, правит admin.
              SliverPadding(
                padding: AppInsets.h8,
                sliver: SliverToBoxAdapter(
                  child: CzMarkedSection(
                    goodId: good.id,
                    marked: good.czMarked,
                  ),
                ),
              ),
              // Марка - сразу под шапкой: ради неё карточку и открыли.
              if (czMark != null)
                SliverPadding(
                  padding: AppInsets.h8,
                  sliver: SliverToBoxAdapter(
                    child: CzMarkSection(scan: czMark!),
                  ),
                ),
              // ШК из марки отвязан (ADHOC-53): вернуть его привязку к этому товару.
              if (czMark?.unboundBarcode != null)
                SliverPadding(
                  padding: AppInsets.h8,
                  sliver: SliverToBoxAdapter(
                    child: UnboundBarcodeNotice(
                      barcode: czMark!.unboundBarcode!,
                    ),
                  ),
                ),
              const SliverToBoxAdapter(child: AppBoxes.kHeight8),
              SliverPadding(
                padding: AppInsets.h8,
                sliver: SliverToBoxAdapter(
                  child: BarcodesSection(
                    goodId: good.id,
                    goodName: good.name,
                    czMarked: good.czMarked,
                  ),
                ),
              ),
              const PlacesSliver(),
            ],
          ),
        ),
        const TotalBar(),
      ],
    );
  }
}
