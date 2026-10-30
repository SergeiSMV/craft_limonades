import 'package:flutter/material.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/error/failure.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';
import '../../../../features/stock/data/catalog_api.dart';
import '../../../../features/stock/data/catalog_models.dart';
import '../settings/access_common.dart';
import '../ui/portal_badge.dart';
import '../ui/portal_button.dart';
import '../ui/portal_card.dart';
import '../ui/portal_modal.dart';

/// Карточка товара «Номенклатуры склада» (ADHOC-56), как карточка товара на ТСД — только
/// просмотр: отметки, реквизиты (каждый своей подписанной строкой) и все штрихкоды товара.
/// Привязка и отвязка ШК, признак ЧЗ и пересорт остаются на ТСД: их делают у товара в руках.
Future<void> showGoodCardDialog(BuildContext context, Good good) => showDialog(
  context: context,
  builder: (_) => _GoodCardDialog(good: good),
);

class _GoodCardDialog extends StatefulWidget {
  const _GoodCardDialog({required this.good});

  final Good good;

  @override
  State<_GoodCardDialog> createState() => _GoodCardDialogState();
}

class _GoodCardDialogState extends State<_GoodCardDialog> {
  final _api = getIt<CatalogApi>();

  List<Barcode>? _barcodes;
  String? _error;

  @override
  void initState() {
    super.initState();
    loadBarcodes();
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
