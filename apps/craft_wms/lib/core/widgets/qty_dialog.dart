import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../constants/app_boxes.dart';
import '../constants/app_insets.dart';
import '../gen/strings.g.dart';
import '../utils/qty_format.dart';

/// Сколько товара взять в руки: по умолчанию — всё доступное, не больше него (размещение,
/// перемещение). [header] — что именно берут, чтобы количество вводили, видя позицию.
///
/// Партия в диалоге не спрашивается: её берут из задания или из источника, а ручной ввод даты
/// как раз и давал бы ошибку, на которой сервер отклонил бы весь документ.
Future<double?> showQtyDialog(
  BuildContext context, {
  required double max,
  required String uom,
  String? title,
  Widget? header,
}) => showDialog<double>(
  context: context,
  builder: (_) => _QtyDialog(max: max, uom: uom, title: title, header: header),
);

class _QtyDialog extends StatefulWidget {
  const _QtyDialog({
    required this.max,
    required this.uom,
    this.title,
    this.header,
  });

  final double max;
  final String uom;

  /// Заголовок вместо общего «Сколько положить» — перемещение берёт, а не кладёт.
  final String? title;

  /// Что берут — над полем количества: товар, партия, сколько его в источнике (P6-04).
  final Widget? header;

  @override
  State<_QtyDialog> createState() => _QtyDialogState();
}

class _QtyDialogState extends State<_QtyDialog> {
  late final _qty = TextEditingController(text: fmtQty(widget.max));
  final _formKey = GlobalKey<FormState>();

  double? _parse(String? v) =>
      double.tryParse((v ?? '').trim().replaceAll(',', '.'));

  /// Проверка: число больше нуля и не больше остатка.
  String? validate(String? v) {
    final q = _parse(v);
    if (q == null || q <= 0 || q > widget.max) {
      return t.qtyDialog.max(max: fmtQty(widget.max));
    }
    return null;
  }

  /// Взять указанное количество.
  void submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    Navigator.of(context).pop(_parse(_qty.text));
  }

  @override
  void dispose() {
    _qty.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      // Во всю ширину с отступом 8 — как диалоги даты и количества в приёмке. scrollable —
      // длинное наименование в блоке «что берут» плюс поднятая клавиатура не помещаются
      // по высоте на DT50S, и диалог прокручивается, а не переполняется.
      insetPadding: AppInsets.h8,
      scrollable: true,
      title: Text(widget.title ?? t.qtyDialog.title),
      content: SizedBox(
        width: double.maxFinite,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.header case final header?) ...[
                header,
                AppBoxes.kHeight16,
              ],
              TextFormField(
                controller: _qty,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                ],
                decoration: InputDecoration(
                  labelText: t.qtyDialog.label(uom: widget.uom),
                ),
                validator: validate,
                onFieldSubmitted: (_) => submit(),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.qtyDialog.cancel),
        ),
        FilledButton(onPressed: submit, child: Text(t.qtyDialog.ok)),
      ],
    );
  }
}
