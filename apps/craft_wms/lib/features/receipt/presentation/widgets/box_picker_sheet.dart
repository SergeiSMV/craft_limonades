import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';
import '../bloc/receipt_cubit.dart';
import '../bloc/receipt_models.dart';

/// Лист выбора короба приёмки — когда QR на ярлыке не читается.
///
/// Короб ищется по короткому коду с ярлыка: поиск зовёт `LoadUnitLabel.normalizeShortCode`
/// (через cubit), поэтому код набирают так, как он напечатан, — с пробелом или без.
/// Возвращает идентификатор выбранного короба.
class BoxPickerSheet extends StatefulWidget {
  const BoxPickerSheet({super.key, required this.cubit, required this.cellOf});

  final ReceiptCubit cubit;

  /// Адрес ячейки короба для подписи.
  final String Function(ReceiptBox box) cellOf;

  @override
  State<BoxPickerSheet> createState() => _BoxPickerSheetState();
}

class _BoxPickerSheetState extends State<BoxPickerSheet> {
  final _controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    _controller.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final boxes = widget.cubit.boxesByShortCode(_controller.text);
    final state = widget.cubit.state;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Padding(
        padding: AppInsets.h16 + AppInsets.bottom24,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              t.receipt.boxesTitle,
              style: SemiboldTextStyles().semiboldInter18,
            ),
            AppBoxes.kHeight12,
            Neumorphic(
              style: NeumorphicStyle(
                shadowLightColor: AppColors.kNeumorphicLight,
                shadowDarkColor: AppColors.kNeumorphicDark,
                intensity: 1,
                color: AppColors.kNeumorphicBg,
                depth: -2,
                shape: NeumorphicShape.flat,
              ),
              child: TextField(
                controller: _controller,
                textCapitalization: TextCapitalization.characters,
                decoration: InputDecoration(
                  prefixIcon: Icon(
                    MdiIcons.packageVariantClosed,
                    size: AppSizes.kIcon25,
                    color: AppColors.kTextMuted,
                  ),
                  hintText: t.receipt.boxSearchHint,
                  hintStyle: RegularTextStyles().regularInter16.copyWith(
                    color: AppColors.kBorderDashed,
                  ),
                  border: const OutlineInputBorder(
                    borderRadius: AppBorders.kCircular8,
                    borderSide: BorderSide.none,
                  ),
                  isDense: true,
                ),
              ),
            ),
            AppBoxes.kHeight12,
            if (boxes.isEmpty)
              Padding(
                padding: AppInsets.v16,
                child: Center(child: Text(t.receipt.nothingFound)),
              )
            else
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.5,
                ),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final b in boxes)
                      ListTile(
                        leading: Icon(
                          MdiIcons.packageVariantClosed,
                          color: b.id == state.currentBoxId
                              ? AppColors.kPrimary
                              : AppColors.kTextMuted,
                        ),
                        title: Text(t.receipt.box(code: b.shortCode)),
                        subtitle: Text(
                          '${t.receipt.boxPositions(count: state.linesInBox(b.id))} · ${widget.cellOf(b)}',
                        ),
                        onTap: () => Navigator.of(context).pop(b.id),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
