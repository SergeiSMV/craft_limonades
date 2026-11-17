import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import '../../features/stock/data/catalog_models.dart';
import '../constants/app_borders.dart';
import '../constants/app_boxes.dart';
import '../constants/app_colors.dart';
import '../constants/app_insets.dart';
import '../constants/app_sizes.dart';
import '../gen/strings.g.dart';
import '../theme/regular_text.dart';
import '../theme/semibold_text.dart';
import '../utils/date_input.dart';
import '../utils/qty_format.dart';

// Общий для «Ввода остатков» и приёмки (P4-09): строка товара в обоих потоках - это партия
// по дате выпуска и количество, и два диалога разошлись бы в правилах проверки ввода.

/// Результат диалога даты/количества: либо добавление (date+qty), либо сигнал «неверный товар»
/// (отвязать ошибочный ШК). [wrongGood] различает эти два исхода.
class DateQtyResult {
  const DateQtyResult.add(this.date, this.qty) : wrongGood = false;
  const DateQtyResult.wrong() : date = '', qty = 0, wrongGood = true;

  final String date;
  final double qty;
  final bool wrongGood;
}

/// Диалог ввода даты выпуска (ДД-ММ-ГГГГ) и количества для строки товара. [allowWrongGood] добавляет
/// кнопку «неверный товар» (только в скан-потоке, когда товар опознан по ШК) - она возвращает сигнал
/// на отвязку ошибочного ШК вместо добавления строки.
class DateQtyDialog extends StatefulWidget {
  const DateQtyDialog({
    super.key,
    required this.good,
    this.initialDate,
    this.initialQty,
    this.allowWrongGood = false,
  });

  final Good good;
  final String?
  initialDate; // префилл при редактировании (для нового товара - null)
  final double? initialQty;
  final bool allowWrongGood;

  @override
  State<DateQtyDialog> createState() => _DateQtyDialogState();
}

class _DateQtyDialogState extends State<DateQtyDialog> {
  late final _date = TextEditingController(text: widget.initialDate ?? '');
  late final _qty = TextEditingController(
    text: widget.initialQty != null ? fmtQty(widget.initialQty!) : '',
  );
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _date.dispose();
    _qty.dispose();
    super.dispose();
  }

  /// Валидировать форму и закрыть диалог с датой (нормализованной к дд.мм.гггг) и количеством.
  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    final qty = double.parse(_qty.text.trim().replaceAll(',', '.'));
    FocusManager.instance.primaryFocus
        ?.unfocus(); // свернуть клавиатуру при подтверждении
    // Год мог быть введён двумя знаками (14.08.26) - приводим к дд.мм.гггг на выходе.
    Navigator.of(
      context,
    ).pop(DateQtyResult.add(normalizeEntryDate(_date.text.trim()), qty));
  }

  /// «Неверный товар»: закрыть диалог с сигналом отвязать ошибочный ШК (обрабатывает экран).
  void _wrongGood() => Navigator.of(context).pop(const DateQtyResult.wrong());

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      // scrollable - чтобы текст ошибки валидации (доп. высота под полем) не переполнял диалог,
      // а прокручивался; особенно при поднятой клавиатуре и малой доступной высоте.
      backgroundColor: Colors.white, // AppColors.kNeumorphicBg,
      scrollable: true,
      insetPadding: AppInsets.h8,
      /*
      title: Text(
        widget.good.name,
        style: SemiboldTextStyles().semiboldInter14.copyWith(
          color: AppColors.kSidebarHover,
        ),
      ),
      */
      content: SizedBox(
        width: double.maxFinite,
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: AppInsets.left6,
                child: Text(
                  widget.good.name,
                  style: SemiboldTextStyles().semiboldInter14.copyWith(
                    color: AppColors.kSidebarHover,
                  ),
                ),
              ),
              AppBoxes.kHeight8,
              Padding(
                padding: AppInsets.left6,
                child: Text(
                  t.dateQty.dateLabel,
                  style: RegularTextStyles().regularInter12.copyWith(
                    color: AppColors.kTextMuted,
                  ),
                ),
              ),
              Neumorphic(
                style: NeumorphicStyle(
                  shadowLightColor: AppColors.kNeumorphicLight,
                  shadowDarkColor: AppColors.kNeumorphicDark,
                  intensity: 1,
                  color: AppColors.kNeumorphicBg,
                  depth: -2,
                  shape: NeumorphicShape.flat,
                ),
                child: TextFormField(
                  cursorColor: AppColors.kTextMuted,
                  cursorWidth: 1.5,
                  cursorHeight: 20,
                  controller: _date,
                  keyboardType: TextInputType.number,
                  inputFormatters: [DateTextInputFormatter()],
                  decoration: InputDecoration(
                    // labelText: t.dateQty.dateLabel,
                    hintText: 'дд.мм.гг(гг)',
                    hintStyle: RegularTextStyles().regularInter14.copyWith(
                      color: AppColors.kBorderDashed,
                    ),
                    border: const OutlineInputBorder(
                      borderRadius: AppBorders.kCircular8,
                      borderSide: BorderSide.none,
                    ),
                  ),
                  validator: (v) => isValidEntryDate((v ?? '').trim())
                      ? null
                      : t.dateQty.dateInvalid,
                ),
              ),
              AppBoxes.kHeight12,
              Padding(
                padding: AppInsets.left6,
                child: Text(
                  t.dateQty.qtyLabel(uom: widget.good.uom),
                  style: RegularTextStyles().regularInter12.copyWith(
                    color: AppColors.kTextMuted,
                  ),
                ),
              ),
              Neumorphic(
                style: NeumorphicStyle(
                  shadowLightColor: AppColors.kNeumorphicLight,
                  shadowDarkColor: AppColors.kNeumorphicDark,
                  intensity: 1,
                  color: AppColors.kNeumorphicBg,
                  depth: -2,
                  shape: NeumorphicShape.flat,
                ),
                child: TextFormField(
                  cursorColor: AppColors.kTextMuted,
                  cursorWidth: 1.5,
                  cursorHeight: 20,
                  controller: _qty,
                  autofocus: true,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    // labelText: t.dateQty.qtyLabel(uom: widget.good.uom),
                    hintText: 'количество',
                    hintStyle: RegularTextStyles().regularInter14.copyWith(
                      color: AppColors.kBorderDashed,
                    ),
                    border: const OutlineInputBorder(
                      borderRadius: AppBorders.kCircular8,
                      borderSide: BorderSide.none,
                    ),
                  ),
                  validator: (v) {
                    final d = double.tryParse(
                      (v ?? '').trim().replaceAll(',', '.'),
                    );
                    return (d != null && d > 0) ? null : t.dateQty.qtyInvalid;
                  },
                ),
              ),
              AppBoxes.kHeight12,
              Row(
                children: [
                  if (widget.allowWrongGood)
                    IconButton(
                      onPressed: _wrongGood,
                      icon: Icon(
                        MdiIcons.barcodeOff,
                        color: AppColors.kDanger,
                        size: AppSizes.kIcon30,
                      ),
                    ),
                  Spacer(),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(t.dateQty.cancel),
                  ),
                  FilledButton(onPressed: _submit, child: Text(t.dateQty.add)),
                ],
              ),
            ],
          ),
        ),
      ),
      // actions: [
      //   // if (widget.allowWrongGood)
      //   //   TextButton(
      //   //     onPressed: _wrongGood,
      //   //     style: TextButton.styleFrom(foregroundColor: AppColors.kDanger),
      //   //     child: Text(t.stockEntry.wrongGood),
      //   //   ),
      //   //   if (widget.allowWrongGood)
      //   //     IconButton(
      //   //       onPressed: _wrongGood,
      //   //       icon: Icon(MdiIcons.barcodeOff, color: AppColors.kDanger),
      //   //     ),
      //   //   Spacer(),
      //   //   TextButton(
      //   //     onPressed: () => Navigator.of(context).pop(),
      //   //     child: Text(t.dateQty.cancel),
      //   //   ),
      //   //   FilledButton(onPressed: _submit, child: Text(t.dateQty.add)),
      // ],
    );
  }
}
