import 'package:flutter/material.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../domain/labels/beam_label.dart';
import '../../../domain/labels/code128.dart';

/// Образец этикетки на балку (ADHOC-57): та же раскладка, что в PDF бэкенда, в масштабе
/// ширины места. Рамка - линия реза.
///
/// Как: части и их края считает [beamLayout]; адрес растягивается по горизонтали ровно на
/// ширину, которую он займёт шрифтом Helvetica-Bold в PDF, - в браузере этого шрифта нет, а
/// без растяжки образец врал бы о зазорах между адресом, кодом и стрелкой.
class LabelPreview extends StatelessWidget {
  const LabelPreview({
    super.key,
    required this.address,
    required this.profile,
    required this.font,
    required this.floor,
    required this.barcode,
  });

  final String address;
  final BeamProfile profile;
  final BeamFont font;
  final bool floor;
  final bool barcode;

  @override
  Widget build(BuildContext context) => AspectRatio(
    aspectRatio: kLabelWidth / profile.height,
    child: CustomPaint(
      painter: _LabelPainter(this),
      child: Semantics(label: address, image: true),
    ),
  );
}

class _LabelPainter extends CustomPainter {
  _LabelPainter(this.label);

  final LabelPreview label;

  @override
  void paint(Canvas canvas, Size size) {
    final p = label.profile;
    final k = size.width / kLabelWidth; // точек на мм
    final cy = p.height / 2;
    canvas.drawRect(Offset.zero & size, Paint()..color = AppColors.kCardBg);
    canvas.drawRect(
      (Offset.zero & size).deflate(0.5),
      Paint()
        ..color = AppColors.kInputBorder
        ..style = PaintingStyle.stroke,
    );
    final ink = Paint()..color = AppColors.kTextMain;
    final parts = beamLayout(
      p,
      label.address,
      label.font.size,
      floor: label.floor,
      barcode: label.barcode,
    );
    for (final (kind, x, w) in parts) {
      switch (kind) {
        case BeamPart.text:
          _text(canvas, x * k, (cy + label.font.capHeight / 2) * k, w * k, k);
        case BeamPart.barcode:
          final top = (cy - p.barcodeHeight / 2) * k;
          for (final (start, width) in code128Bars(label.address)) {
            canvas.drawRect(
              Rect.fromLTWH(
                (x + p.quiet + start * p.module) * k,
                top,
                width * p.module * k,
                p.barcodeHeight * k,
              ),
              ink,
            );
          }
        case BeamPart.arrow:
          final pts = arrowPolygon(x + w / 2, cy, p.arrowWidth, p.arrowHeight);
          canvas.drawPath(
            Path()..addPolygon([
              for (final (px, py) in pts) Offset(px * k, py * k),
            ], true),
            ink,
          );
      }
    }
  }

  /// Адрес: базовая линия на [baseline], ширина - ровно [width].
  void _text(Canvas canvas, double x, double baseline, double width, double k) {
    final tp = TextPainter(
      text: TextSpan(
        text: label.address,
        style: TextStyle(
          fontSize: label.font.size * k,
          fontWeight: FontWeight.w700,
          color: AppColors.kTextMain,
          height: 1,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final ascent = tp.computeDistanceToActualBaseline(TextBaseline.alphabetic);
    canvas
      ..save()
      ..translate(x, baseline - ascent)
      ..scale(tp.width > 0 ? width / tp.width : 1, 1);
    tp.paint(canvas, Offset.zero);
    canvas.restore();
    tp.dispose();
  }

  @override
  bool shouldRepaint(_LabelPainter old) =>
      old.label.address != label.address ||
      old.label.profile != label.profile ||
      old.label.font.size != label.font.size ||
      old.label.floor != label.floor ||
      old.label.barcode != label.barcode;
}
