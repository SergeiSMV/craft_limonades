import 'package:flutter/material.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';
import '../../../../features/stock/data/catalog_models.dart';
import '../ui/portal_badge.dart';
import '../ui/portal_button.dart';
import '../ui/portal_card.dart';

/// Карточка списка «Номенклатуры склада» (ADHOC-56): товары, под ними — сколько показано и
/// «Показать ещё». Нажатие на строку открывает карточку товара.
///
/// Раскладка — по ширине карточки: от [AppSizes.kGoodsColumnsWidth] — таблицей с шапкой
/// колонок, уже — строками, где каждый реквизит своей подписанной строкой.
class GoodsListCard extends StatelessWidget {
  const GoodsListCard({
    super.key,
    required this.goods,
    required this.total,
    required this.loadingMore,
    required this.onMore,
    required this.onOpen,
    this.qty,
  });

  final List<Good> goods;

  /// Сколько товаров под текущие поиск и фильтры всего.
  final int total;
  final bool loadingMore;
  final VoidCallback onMore;

  /// Открыть карточку товара — нажатием на строку.
  final ValueChanged<Good> onOpen;

  /// Остаток товара подписью («12 шт»); задан — последняя колонка «Остаток» вместо «Ед.»
  /// (страница «Остатки склада»).
  final String Function(Good)? qty;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= AppSizes.kGoodsColumnsWidth;
        return PortalCard(
          children: [
            if (columns) _HeaderRow(stock: qty != null),
            if (goods.isEmpty)
              Padding(
                padding: AppInsets.cardRow,
                child: Text(
                  t.portal.goods.empty,
                  style: RegularTextStyles().regularInter13.copyWith(
                    color: AppColors.kTextMuted,
                  ),
                ),
              ),
            for (final g in goods)
              // Строка — нажимаемая целиком, с подсветкой при наведении, как в Polaris.
              InkWell(
                onTap: () => onOpen(g),
                hoverColor: AppColors.kBg,
                child: columns
                    ? _ColumnsRow(good: g, qty: qty?.call(g))
                    : _StackedRow(good: g, qty: qty?.call(g)),
              ),
            if (goods.isNotEmpty) _Footer(this),
          ],
        );
      },
    );
  }
}

/// Шапка колонок таблицы.
class _HeaderRow extends StatelessWidget {
  const _HeaderRow({required this.stock});

  /// Последняя колонка — «Остаток», а не «Ед.».
  final bool stock;

  @override
  Widget build(BuildContext context) {
    final g = t.portal.goods;
    final style = SemiboldTextStyles().semiboldInter12.copyWith(
      color: AppColors.kTextMuted,
    );
    return Padding(
      padding: AppInsets.tableHead,
      child: _Columns(
        name: Text(g.colName, style: style),
        code: Text(g.colCode, style: style),
        group: Text(g.colGroup, style: style),
        supplier: Text(g.colSupplier, style: style),
        uom: Text(stock ? g.colQty : g.colUom, style: style),
        wide: stock,
      ),
    );
  }
}

/// Строка таблицы: наименование с отметками и реквизиты по колонкам.
class _ColumnsRow extends StatelessWidget {
  const _ColumnsRow({required this.good, this.qty});

  final Good good;

  /// Остаток подписью; `null` — колонка «Ед.».
  final String? qty;

  @override
  Widget build(BuildContext context) {
    final muted = RegularTextStyles().regularInter13.copyWith(
      color: AppColors.kTextSecondary,
    );
    Text cell(String? value) => Text(
      value ?? '',
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: muted,
    );
    return Padding(
      padding: AppInsets.cardRow,
      child: _Columns(
        name: _Name(good: good),
        code: cell(good.code),
        group: cell(good.groupName),
        supplier: cell(good.supplierName),
        uom: qty == null
            ? cell(good.uom)
            : Text(
                qty!,
                style: SemiboldTextStyles().semiboldInter13.copyWith(
                  color: AppColors.kTextMain,
                ),
              ),
        wide: qty != null,
      ),
    );
  }
}

/// Раскладка колонок — общая у шапки и строк, чтобы они не разошлись.
class _Columns extends StatelessWidget {
  const _Columns({
    required this.name,
    required this.code,
    required this.group,
    required this.supplier,
    required this.uom,
    this.wide = false,
  });

  final Widget name;
  final Widget code;
  final Widget group;
  final Widget supplier;
  final Widget uom;

  /// Последняя колонка шире — остаток с единицей, а не одна единица.
  final bool wide;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(flex: 5, child: name),
      AppBoxes.kWidth16,
      SizedBox(width: AppSizes.kGoodsColCode, child: code),
      AppBoxes.kWidth16,
      Expanded(flex: 3, child: group),
      AppBoxes.kWidth16,
      Expanded(flex: 3, child: supplier),
      AppBoxes.kWidth16,
      SizedBox(
        width: wide ? AppSizes.kGoodsColQty : AppSizes.kGoodsColUom,
        child: uom,
      ),
    ],
  );
}

/// Строка узкого списка: наименование, под ним реквизиты — каждый своей подписанной строкой.
class _StackedRow extends StatelessWidget {
  const _StackedRow({required this.good, this.qty});

  final Good good;

  /// Остаток подписью; `null` — строка «Единица».
  final String? qty;

  @override
  Widget build(BuildContext context) {
    final g = t.portal.goods;
    final muted = RegularTextStyles().regularInter12.copyWith(
      color: AppColors.kTextSecondary,
    );
    return Padding(
      padding: AppInsets.cardRow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Name(good: good),
          AppBoxes.kHeight4,
          if (good.code != null) Text(g.code(value: good.code!), style: muted),
          if (good.groupName != null)
            Text(g.groupLine(value: good.groupName!), style: muted),
          if (good.supplierName != null)
            Text(g.supplierLine(value: good.supplierName!), style: muted),
          if (qty == null)
            Text(g.uom(value: good.uom), style: muted)
          else
            Text(
              g.qtyLine(value: qty!),
              style: SemiboldTextStyles().semiboldInter12.copyWith(
                color: AppColors.kTextMain,
              ),
            ),
        ],
      ),
    );
  }
}

/// Наименование товара и его отметки: маркируемый (ЧЗ), не активен в 1С.
class _Name extends StatelessWidget {
  const _Name({required this.good});

  final Good good;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: AppSizes.kChipSpacing,
    runSpacing: AppSizes.kChipSpacing,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      Text(
        good.name,
        style: SemiboldTextStyles().semiboldInter13.copyWith(
          color: AppColors.kTextMain,
        ),
      ),
      if (good.czMarked)
        PortalBadge(t.portal.goods.cz, tone: PortalBadgeTone.info),
      if (!good.isActive) PortalBadge(t.portal.goods.inactive),
    ],
  );
}

/// Подвал списка: сколько показано из скольких и «Показать ещё», пока показаны не все.
class _Footer extends StatelessWidget {
  const _Footer(this.card);

  final GoodsListCard card;

  @override
  Widget build(BuildContext context) => Padding(
    padding: AppInsets.cardRow,
    child: Row(
      children: [
        Expanded(
          child: Text(
            t.portal.goods.shown(shown: card.goods.length, total: card.total),
            style: RegularTextStyles().regularInter13.copyWith(
              color: AppColors.kTextMuted,
            ),
          ),
        ),
        if (card.goods.length < card.total)
          PortalButton(
            label: t.portal.goods.more,
            busy: card.loadingMore,
            onPressed: card.onMore,
          ),
      ],
    ),
  );
}
