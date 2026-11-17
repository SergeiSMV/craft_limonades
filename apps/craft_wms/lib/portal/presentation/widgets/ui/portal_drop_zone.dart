import 'package:flutter/material.dart';

import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';

/// Зона выбора файла в плоском стиле (ADHOC-56, DropZone Shopify Polaris).
///
/// Что: пунктирная рамка с иконкой, подсказкой и форматом; нажатие открывает выбор файла
///      браузера, после выбора вместо подсказки - имя файла.
/// Как: при наведении рамка синяя, как поле в фокусе; пока файл грузится ([onTap] = `null`),
///      зона не нажимается.
class PortalDropZone extends StatefulWidget {
  const PortalDropZone({
    super.key,
    required this.prompt,
    required this.hint,
    required this.onTap,
    this.filename,
  });

  /// Призыв выбрать файл («Выберите файл .xls»).
  final String prompt;

  /// Пояснение под ним - формат и откуда файл.
  final String hint;
  final VoidCallback? onTap;

  /// Выбранный файл; `null` - ещё не выбран.
  final String? filename;

  @override
  State<PortalDropZone> createState() => _PortalDropZoneState();
}

class _PortalDropZoneState extends State<PortalDropZone> {
  bool _hover = false;

  /// Мышь над зоной или ушла с неё.
  void setHover(bool value) => setState(() => _hover = value);

  @override
  Widget build(BuildContext context) {
    final active = _hover && widget.onTap != null;
    return MouseRegion(
      onEnter: (_) => setHover(true),
      onExit: (_) => setHover(false),
      cursor: widget.onTap != null
          ? SystemMouseCursors.click
          : MouseCursor.defer,
      child: GestureDetector(
        onTap: widget.onTap,
        child: CustomPaint(
          painter: _DashedBorderPainter(
            color: active ? AppColors.kFocus : AppColors.kInputBorder,
          ),
          child: Padding(
            padding: AppInsets.dropZone,
            child: Column(
              children: [
                Icon(
                  widget.filename == null
                      ? Icons.upload_file_outlined
                      : Icons.description_outlined,
                  size: AppSizes.kIcon24,
                  color: AppColors.kTextMuted,
                ),
                AppBoxes.kHeight8,
                Text(
                  widget.filename ?? widget.prompt,
                  textAlign: TextAlign.center,
                  style: SemiboldTextStyles().semiboldInter13.copyWith(
                    color: AppColors.kTextMain,
                  ),
                ),
                AppBoxes.kHeight4,
                Text(
                  widget.hint,
                  textAlign: TextAlign.center,
                  style: RegularTextStyles().regularInter12.copyWith(
                    color: AppColors.kTextMuted,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Пунктирная скруглённая рамка (в Material нет из коробки - рисуем сами): штрихи 6 через 4.
class _DashedBorderPainter extends CustomPainter {
  _DashedBorderPainter({required this.color});

  final Color color;

  static const _dash = 6.0;
  static const _gap = 4.0;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    final path = Path()
      ..addRRect(AppBorders.kCircular8.toRRect(Offset.zero & size));
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        canvas.drawPath(metric.extractPath(distance, distance + _dash), paint);
        distance += _dash + _gap;
      }
    }
  }

  /// Перерисовываем только при смене цвета рамки.
  @override
  bool shouldRepaint(_DashedBorderPainter old) => old.color != color;
}
