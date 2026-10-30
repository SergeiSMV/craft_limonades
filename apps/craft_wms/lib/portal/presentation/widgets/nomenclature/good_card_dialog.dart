import 'package:flutter/material.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/error/failure.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/printer/load_unit_label.dart';
import '../../../../core/theme/semibold_text.dart';
import '../../../../core/utils/date_time_format.dart';
import '../../../../core/utils/qty_format.dart';
import '../../../../features/stock/data/catalog_api.dart';
import '../../../../features/stock/data/catalog_models.dart';
import '../../../data/warehouse_stock_repository.dart';
import '../settings/access_common.dart';
import '../ui/portal_badge.dart';
import '../ui/portal_button.dart';
import '../ui/portal_card.dart';
import '../ui/portal_modal.dart';

/// Карточка товара (ADHOC-56), как карточка товара на ТСД — только просмотр: отметки,
/// реквизиты (каждый своей подписанной строкой), все штрихкоды и, с [withPlaces], наличие по
/// местам хранения с итогом. Привязка и отвязка ШК, признак ЧЗ и пересорт остаются на ТСД:
/// их делают у товара в руках.
///
/// [withPlaces] — по праву «Остатки склада: смотреть». Места берутся из последнего снимка
/// склада ([WarehouseStockRepository]); снимка ещё нет — он загружается.
Future<void> showGoodCardDialog(
  BuildContext context,
  Good good, {
  bool withPlaces = false,
}) => showDialog(
  context: context,
  builder: (_) => _GoodCardDialog(good: good, withPlaces: withPlaces),
);

class _GoodCardDialog extends StatefulWidget {
  const _GoodCardDialog({required this.good, required this.withPlaces});

  final Good good;
  final bool withPlaces;

  @override
  State<_GoodCardDialog> createState() => _GoodCardDialogState();
}

class _GoodCardDialogState extends State<_GoodCardDialog> {
  final _api = getIt<CatalogApi>();

  List<Barcode>? _barcodes;
  String? _error;

  List<PortalStockPlace>? _places;
  String? _placesError;

  @override
  void initState() {
    super.initState();
    loadBarcodes();
    if (widget.withPlaces) loadPlaces();
  }

  /// Места товара из последнего снимка склада.
  Future<void> loadPlaces() async {
    final res = await getIt<WarehouseStockRepository>().load(refresh: false);
    if (!mounted) return;
    setState(
      () => res.fold(
        (f) => _placesError = _text(f),
        (s) => _places = s.places[widget.good.id] ?? const [],
      ),
    );
  }

  /// Штрихкоды товара с сервера.
  Future<void> loadBarcodes() async {
    final res = await _api.listGoodBarcodes(widget.good.id);
    if (!mounted) return;
    setState(() => res.fold((f) => _error = _text(f), (b) => _barcodes = b));
  }

  String _text(Failure f) => switch (f) {
    ServerFailure(:final message?) => message,
    ServerFailure(:final statusCode) => t.portal.goods.errorCode(
      code: statusCode,
    ),
    NetworkFailure() => t.portal.login.errorNetwork,
    _ => t.portal.login.errorUnknown,
  };

  /// Места хранения строками и итог; пусто — «Нет остатков».
  Widget _placesCard(Good good) {
    final g = t.portal.goods;
    final places = _places;
    final muted = RegularTextStyles().regularInter13.copyWith(
      color: AppColors.kTextMuted,
    );
    final total = (places ?? const <PortalStockPlace>[]).fold<double>(
      0,
      (sum, p) => sum + p.qty,
    );
    return SettingsListCard(
      loading: places == null && _placesError == null,
      error: _placesError,
      rows: [
        if (places != null && places.isEmpty)
          Padding(
            padding: AppInsets.cardRow,
            child: Text(g.cardNoPlaces, style: muted),
          ),
        for (final p in places ?? const <PortalStockPlace>[])
          _PlaceRow(place: p),
        if (places != null && places.isNotEmpty)
          Padding(
            padding: AppInsets.cardRow,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    g.cardTotal,
                    style: SemiboldTextStyles().semiboldInter13.copyWith(
                      color: AppColors.kTextMain,
                    ),
                  ),
                ),
                Text(
                  t.portal.stock.qty(qty: fmtQty(total), uom: good.uom),
                  style: SemiboldTextStyles().semiboldInter13.copyWith(
                    color: AppColors.kTextMain,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final good = widget.good;
    final g = t.portal.goods;
    final barcodes = _barcodes;
    final fullName = good.fullName;
    return PortalModal(
      title: good.name,
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (good.czMarked || !good.isActive) ...[
            Wrap(
              spacing: AppSizes.kChipSpacing,
              children: [
                if (good.czMarked)
                  PortalBadge(g.cz, tone: PortalBadgeTone.info),
                if (!good.isActive) PortalBadge(g.inactive),
              ],
            ),
            portalFieldGap,
          ],
          PortalFieldLabel(g.cardProps),
          PortalCard(
            children: [
              // Полное наименование 1С — только если оно отличается от краткого.
              if (fullName != null &&
                  fullName.isNotEmpty &&
                  fullName != good.name)
                _Prop(g.cardFullName, fullName),
              if (good.code != null) _Prop(g.cardCode, good.code!),
              _Prop(g.cardUom, good.uom),
              if (good.groupName != null) _Prop(g.cardGroup, good.groupName!),
              if (good.supplierName != null)
                _Prop(g.cardSupplier, good.supplierName!),
            ],
          ),
          portalFieldGap,
          PortalFieldLabel(
            barcodes == null
                ? g.cardBarcodesTitle
                : g.cardBarcodes(count: barcodes.length),
          ),
          SettingsListCard(
            loading: barcodes == null && _error == null,
            error: _error,
            rows: [
              if (barcodes != null && barcodes.isEmpty)
                Padding(
                  padding: AppInsets.cardRow,
                  child: Text(
                    g.cardNoBarcodes,
                    style: RegularTextStyles().regularInter13.copyWith(
                      color: AppColors.kTextMuted,
                    ),
                  ),
                ),
              for (final b in barcodes ?? const <Barcode>[]) _BarcodeRow(b),
            ],
          ),
          if (widget.withPlaces) ...[
            portalFieldGap,
            PortalFieldLabel(g.cardPlaces),
            _placesCard(good),
          ],
        ],
      ),
      actions: [
        PortalButton(
          label: t.portal.common.close,
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }
}

/// Реквизит строкой: подпись слева, значение справа; уже — значение под подписью.
class _Prop extends StatelessWidget {
  const _Prop(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final labelText = Text(
      label,
      style: RegularTextStyles().regularInter13.copyWith(
        color: AppColors.kTextMuted,
      ),
    );
    final valueText = SelectableText(
      value,
      style: RegularTextStyles().regularInter13.copyWith(
        color: AppColors.kTextMain,
      ),
    );
    return Padding(
      padding: AppInsets.cardRow,
      child: LayoutBuilder(
        builder: (context, constraints) =>
            constraints.maxWidth < AppSizes.kGoodCardLabel * 2
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [labelText, AppBoxes.kHeight4, valueText],
              )
            : Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: AppSizes.kGoodCardLabel, child: labelText),
                  Expanded(child: valueText),
                ],
              ),
      ),
    );
  }
}

/// Штрихкод товара: код (его можно выделить и скопировать) и символика, если известна.
class _BarcodeRow extends StatelessWidget {
  const _BarcodeRow(this.barcode);

  final Barcode barcode;

  @override
  Widget build(BuildContext context) => Padding(
    padding: AppInsets.cardRow,
    child: Row(
      children: [
        Expanded(
          child: SelectableText(
            barcode.barcode,
            style: SemiboldTextStyles().semiboldInter13.copyWith(
              color: AppColors.kTextMain,
            ),
          ),
        ),
        if (barcode.symbology != null) PortalBadge(barcode.symbology!),
      ],
    ),
  );
}

/// Место хранения строкой, как на ТСД: адрес ячейки, под ним короб и партия — каждый своей
/// подписанной строкой, склад — отметкой (только не основной); количество справа.
class _PlaceRow extends StatelessWidget {
  const _PlaceRow({required this.place});

  final PortalStockPlace place;

  @override
  Widget build(BuildContext context) {
    final g = t.portal.goods;
    final muted = RegularTextStyles().regularInter12.copyWith(
      color: AppColors.kTextMuted,
    );
    return Padding(
      padding: AppInsets.cardRow,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  place.cellAddress.isEmpty
                      ? g.cardUnknownCell
                      : place.cellAddress,
                  style: SemiboldTextStyles().semiboldInter13.copyWith(
                    color: AppColors.kTextMain,
                  ),
                ),
                if (place.loadUnitId case final box?)
                  Text(
                    g.cardBox(code: LoadUnitLabel(box).shortCodeFormatted),
                    style: muted,
                  ),
                Text(
                  g.cardBatch(date: batchDate(place.productionDate)),
                  style: muted,
                ),
                if (!place.onDefaultWarehouse &&
                    place.warehouseName.isNotEmpty) ...[
                  AppBoxes.kHeight4,
                  PortalBadge(
                    place.warehouseName,
                    tone: PortalBadgeTone.warning,
                  ),
                ],
              ],
            ),
          ),
          AppBoxes.kWidth16,
          Text(
            fmtQty(place.qty),
            style: SemiboldTextStyles().semiboldInter13.copyWith(
              color: AppColors.kTextMain,
            ),
          ),
        ],
      ),
    );
  }
}
