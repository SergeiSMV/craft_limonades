import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../../core/gen/strings.g.dart';
import '../../../../../core/printer/label_geometry.dart';

/// Размер заправленного рулона: ширина, высота и промежуток между этикетками.
///
/// Зачем это на экране: принтер не знает, что в него заправлено, — размер ему объявляют
/// командой. Объявишь высоту с запасом, и после печати он догонит ленту до следующего
/// промежутка: выедет вторая этикетка, пустая. Промахнёшься с промежутком — датчик не найдёт
/// зазор и промотает рулон целиком. Оба симптома наблюдались на живом принтере.
class LabelGeometryCard extends StatefulWidget {
  const LabelGeometryCard({
    required this.geometry,
    required this.onChanged,
    super.key,
  });

  final LabelGeometry geometry;
  final ValueChanged<LabelGeometry> onChanged;

  @override
  State<LabelGeometryCard> createState() => _LabelGeometryCardState();
}

class _LabelGeometryCardState extends State<LabelGeometryCard> {
  late final TextEditingController _width;
  late final TextEditingController _height;
  late final TextEditingController _gap;

  @override
  void initState() {
    super.initState();
    _width = TextEditingController(text: _text(widget.geometry.widthMm));
    _height = TextEditingController(text: _text(widget.geometry.heightMm));
    _gap = TextEditingController(text: _text(widget.geometry.gapMm));
  }

  @override
  void didUpdateWidget(LabelGeometryCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Значение могло прийти из настроек позже первой отрисовки — подхватываем, но не затираем
    // то, что человек печатает прямо сейчас.
    if (oldWidget.geometry == widget.geometry) return;
    _width.text = _text(widget.geometry.widthMm);
    _height.text = _text(widget.geometry.heightMm);
    _gap.text = _text(widget.geometry.gapMm);
  }

  @override
  void dispose() {
    _width.dispose();
    _height.dispose();
    _gap.dispose();
    super.dispose();
  }

  static String _text(double value) =>
      value == value.roundToDouble() ? '${value.round()}' : '$value';

  /// Собрать размер из полей и отдать наверх. Непрочитанное поле не рушит ввод —
  /// на его месте остаётся прежнее значение.
  void submit() {
    final current = widget.geometry;
    widget.onChanged(
      LabelGeometry(
        widthMm:
            double.tryParse(_width.text.replaceAll(',', '.')) ??
            current.widthMm,
        heightMm:
            double.tryParse(_height.text.replaceAll(',', '.')) ??
            current.heightMm,
        gapMm: double.tryParse(_gap.text.replaceAll(',', '.')) ?? current.gapMm,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              t.printerProbe.geometry,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: _field(_width, t.printerProbe.width)),
                const SizedBox(width: 8),
                Expanded(child: _field(_height, t.printerProbe.height)),
                const SizedBox(width: 8),
                Expanded(child: _field(_gap, t.printerProbe.gap)),
              ],
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: submit,
                child: Text(t.printerProbe.applyGeometry),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _field(TextEditingController controller, String label) {
    return TextField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
      decoration: InputDecoration(labelText: label, isDense: true),
      onSubmitted: (_) => submit(),
    );
  }
}
