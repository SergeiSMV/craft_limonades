import 'package:flutter/material.dart';

import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';

/// Общие виджеты вкладок импорта портала (Номенклатура/Ячейки) — чтобы не дублировать
/// зону загрузки, пунктирную рамку и строку статистики отчёта.

/// Зона загрузки по макету: пунктирная рамка, иконка, подсказки, бейдж формата.
/// Клик открывает выбор файла; при наведении рамка янтарная. После выбора показывает имя файла.
/// Тексты (prompt/hint/badge) и иконка передаются — зона переиспользуется разными вкладками.
class PortalUploadZone extends StatelessWidget {
  const PortalUploadZone({
    super.key,
    required this.filename,
    required this.hovering,
    required this.onTap,
    required this.onHover,
    required this.prompt,
    required this.hint,
    required this.badge,
    this.icon = Icons.description_outlined,
  });

  final String? filename;
  final bool hovering;
  final VoidCallback? onTap;
  final ValueChanged<bool> onHover;
  final String prompt;
  final String hint;
  final String badge;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final active = hovering && onTap != null;
    return MouseRegion(
      onEnter: (_) => onHover(true),
      onExit: (_) => onHover(false),
      cursor: onTap != null ? SystemMouseCursors.click : MouseCursor.defer,
      child: GestureDetector(
        onTap: onTap,
        child: CustomPaint(
          painter: _DashedBorderPainter(
            color: active ? AppColors.kPrimary : AppColors.kBorderDashed,
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: active ? AppColors.kPrimarySoft : AppColors.kFieldBg,
              borderRadius: AppBorders.kCircular12,
            ),
            child: Padding(
              padding: AppInsets.uploadZone,
              child: Column(
                children: [
                  Icon(icon, size: AppSizes.kIcon48, color: AppColors.kPrimary),
                  AppBoxes.kHeight16,
                  Text(
                    filename ?? prompt,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: AppSizes.kText18,
                      fontWeight: FontWeight.w600,
                      color: AppColors.kTextMain,
                    ),
                  ),
                  AppBoxes.kHeight8,
                  Text(
                    hint,
                    style: const TextStyle(fontSize: AppSizes.kText14, color: AppColors.kTextMuted),
                  ),
                  AppBoxes.kHeight16,
                  Container(
                    padding: AppInsets.badge,
                    decoration: const BoxDecoration(
                      color: AppColors.kBorder,
                      borderRadius: AppBorders.kPill,
                    ),
                    child: Text(
                      badge,
                      style: const TextStyle(
                        fontSize: AppSizes.kText12,
                        fontWeight: FontWeight.w500,
                        color: AppColors.kTextMuted,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Пунктирная скруглённая рамка (в Material нет из коробки — рисуем сами).
class _DashedBorderPainter extends CustomPainter {
  _DashedBorderPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = AppSizes.kIcon2
      ..style = PaintingStyle.stroke;

    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(12),
    );
    final path = Path()..addRRect(rrect);

    // Разбиваем контур на штрихи 6px через 4px.
    const dash = 6.0;
    const gap = 4.0;
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        canvas.drawPath(metric.extractPath(distance, distance + dash), paint);
        distance += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorderPainter old) => old.color != color;
}

/// Строка «метка — число» в карточке отчёта импорта.
class PortalStatRow extends StatelessWidget {
  const PortalStatRow({super.key, required this.label, required this.value});

  final String label;
  final int value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: AppInsets.v4,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontSize: AppSizes.kText16)),
          Text(
            '$value',
            style: const TextStyle(fontSize: AppSizes.kText16, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}
