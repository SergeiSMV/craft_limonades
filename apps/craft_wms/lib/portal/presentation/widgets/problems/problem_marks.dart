import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';
import '../ui/portal_button.dart';

/// Марки ЧЗ проблемы склада (ADHOC-52, плоский стиль - ADHOC-56): заголовок и марки построчно,
/// каждая с копированием.
///
/// Зачем копирование: «не наша марка» офис проверяет по самой марке - в ЛК ЧЗ или у
/// поставщика, а набирать КИ вручную с экрана долго и с ошибками.
class ProblemMarks extends StatelessWidget {
  const ProblemMarks({super.key, required this.marks});

  /// КИ марок в порядке показа.
  final List<String> marks;

  @override
  Widget build(BuildContext context) {
    final main = RegularTextStyles().regularInter13.copyWith(
      color: AppColors.kTextMain,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          t.portal.problems.marksTitle,
          style: SemiboldTextStyles().semiboldInter12.copyWith(
            color: AppColors.kTextMuted,
          ),
        ),
        for (final mark in marks)
          Row(
            children: [
              Flexible(child: SelectableText(mark, style: main)),
              PortalIconButton(
                icon: Icons.copy,
                tooltip: t.portal.problems.markCopy,
                onPressed: () => _copy(context, mark),
              ),
            ],
          ),
      ],
    );
  }

  /// Кладёт марку в буфер обмена и подтверждает это всплывашкой.
  Future<void> _copy(BuildContext context, String mark) async {
    await Clipboard.setData(ClipboardData(text: mark));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(t.portal.problems.markCopied)));
  }
}
