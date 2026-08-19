import 'package:flutter/material.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/semibold_text.dart';
import '../../../../core/utils/date_input.dart';
import '../../../../core/utils/qty_format.dart';
import '../../../stock/data/catalog_models.dart';

/// Результат диалога даты/количества: либо добавление (date+qty), либо сигнал «неверный товар»
/// (отвязать ошибочный ШК). [wrongGood] различает эти два исхода.
class DateQtyResult {
  const DateQtyResult.add(this.date, this.qty) : wrongGood = false;
  const DateQtyResult.wrong()
      : date = '',
        qty = 0,
        wrongGood = true;

  final String date;
  final double qty;
  final bool wrongGood;
}

/// Диалог ввода даты выпуска (ДД-ММ-ГГГГ) и количества для строки товара. [allowWrongGood] добавляет
/// кнопку «неверный товар» (только в скан-потоке, когда товар опознан по ШК) — она возвращает сигнал
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
  initialDate; // префилл при редактировании (для нового товара — null)
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
    // Год мог быть введён двумя знаками (14.08.26) — приводим к дд.мм.гггг на выходе.
    Navigator.of(context).pop(
      DateQtyResult.add(normalizeEntryDate(_date.text.trim()), qty),
    );
  }

  /// «Неверный товар»: закрыть диалог с сигналом отвязать ошибочный ШК (обрабатывает экран).
  void _wrongGood() => Navigator.of(context).pop(const DateQtyResult.wrong());

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      // scrollable — чтобы текст ошибки валидации (доп. высота под полем) не переполнял диалог,
      // а прокручивался; особенно при поднятой клавиатуре и малой доступной высоте.
      scrollable: true,
      title: Text(
        widget.good.name,
        style: SemiboldTextStyles().semiboldInter16,
      ),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _date,
              keyboardType: TextInputType.number,
              inputFormatters: [DateTextInputFormatter()],
              decoration: InputDecoration(
                labelText: t.stockEntry.dateLabel,
                hintText: 'дд.мм.гг(гг)',
              ),
              validator: (v) => isValidEntryDate((v ?? '').trim())
                  ? null
                  : t.stockEntry.dateInvalid,
            ),
            AppBoxes.kHeight12,
            TextFormField(
              controller: _qty,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                labelText: t.stockEntry.qtyLabel(uom: widget.good.uom),
              ),
              validator: (v) {
                final d = double.tryParse(
                  (v ?? '').trim().replaceAll(',', '.'),
                );
                return (d != null && d > 0) ? null : t.stockEntry.qtyInvalid;
              },
            ),
          ],
        ),
      ),
      actions: [
        if (widget.allowWrongGood)
          TextButton(
            onPressed: _wrongGood,
            style: TextButton.styleFrom(foregroundColor: AppColors.kDanger),
            child: Text(t.stockEntry.wrongGood),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.stockEntry.cancel),
        ),
        FilledButton(onPressed: _submit, child: Text(t.stockEntry.add)),
      ],
    );
  }
}
