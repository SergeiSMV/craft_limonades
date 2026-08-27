import 'package:flutter/material.dart';

import '../../../../../core/constants/app_boxes.dart';
import '../../../../../core/constants/app_colors.dart';
import '../../../../../core/constants/app_insets.dart';
import '../../../../../core/constants/app_sizes.dart';
import 'detail_card.dart';

/// Белая плашка с раскрывающимся содержимым: шапка с шевроном видна всегда, тело
/// раскрывается тапом по шапке. По умолчанию свёрнута.
///
/// Общий механизм для карточки товара и списка штрихкодов — чтобы анимация, шеврон
/// и зона тапа были описаны в одном месте.
class ExpandableCard extends StatefulWidget {
  const ExpandableCard({
    super.key,
    required this.headerBuilder,
    required this.child,
  });

  /// Содержимое шапки. Получает текущее состояние — например, чтобы обрезать длинный
  /// текст в свёрнутом виде и показывать целиком в раскрытом.
  final Widget Function(bool expanded) headerBuilder;

  /// Раскрывающееся содержимое плашки.
  final Widget child;

  @override
  State<ExpandableCard> createState() => _ExpandableCardState();
}

class _ExpandableCardState extends State<ExpandableCard> {
  /// Раскрыто ли содержимое.
  bool _expanded = false;

  /// Раскрыть/свернуть содержимое плашки.
  void toggle() => setState(() => _expanded = !_expanded);

  @override
  Widget build(BuildContext context) {
    return DetailCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: toggle,
            child: Padding(
              padding: AppInsets.all16,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: widget.headerBuilder(_expanded)),
                  AppBoxes.kWidth8,
                  AnimatedRotation(
                    turns: _expanded ? 0.5 : 0,
                    duration: _animation,
                    child: const Icon(
                      Icons.keyboard_arrow_down_rounded,
                      size: AppSizes.kIcon28,
                      color: AppColors.kTextMuted,
                    ),
                  ),
                ],
              ),
            ),
          ),
          AnimatedCrossFade(
            duration: _animation,
            sizeCurve: Curves.easeOut,
            crossFadeState: _expanded
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            firstChild: const SizedBox(width: double.infinity),
            secondChild: widget.child,
          ),
        ],
      ),
    );
  }

  /// Длительность раскрытия/сворачивания.
  static const Duration _animation = Duration(milliseconds: 200);
}
