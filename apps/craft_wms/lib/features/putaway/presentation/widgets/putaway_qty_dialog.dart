import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/gen/strings.g.dart';
import '../../../../core/utils/qty_format.dart';

/// Сколько россыпи взять в руки: по умолчанию — весь остаток позиции, не больше него.
///
/// Партия в диалоге не спрашивается: она из задания, а ручной ввод даты как раз и давал бы
/// ошибку, на которой сервер отклонил бы весь сеанс.
Future<double?> showPutawayQtyDialog(
  BuildContext context, {
  required double max,
  required String uom,
}) => showDialog<double>(
  context: context,
  builder: (_) => _QtyDialog(max: max, uom: uom),
);

class _QtyDialog extends StatefulWidget {
  const _QtyDialog({required this.max, required this.uom});

  final double max;
  final String uom;

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
      return t.putaway.qtyMax(max: fmtQty(widget.max));
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
      title: Text(t.putaway.qtyTitle),
      content: Form(
        key: _formKey,
        child: TextFormField(
          controller: _qty,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
          ],
          decoration: InputDecoration(
            labelText: t.putaway.qtyLabel(uom: widget.uom),
          ),
          validator: validate,
          onFieldSubmitted: (_) => submit(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.putaway.qtyCancel),
        ),
        FilledButton(onPressed: submit, child: Text(t.putaway.qtyOk)),
      ],
    );
  }
}
