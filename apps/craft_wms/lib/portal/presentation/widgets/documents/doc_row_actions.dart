import 'package:flutter/material.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/gen/strings.g.dart';
import '../common/neumorphic_icon_button.dart';
import '../common/neumorphic_text_button.dart';

/// Действия строки таблицы документов (ADHOC-26): история, скачать .xlsx, провести —
/// у проведённого кнопки «Провести» нет. [compact] — скачивание и проведение иконками
/// с подсказкой вместо подписей: так ряд помещается на ширине ноутбука.
class DocRowActions extends StatelessWidget {
  const DocRowActions({
    super.key,
    required this.posted,
    required this.compact,
    required this.downloading,
    required this.posting,
    required this.onHistory,
    required this.onDownload,
    required this.onPost,
  });

  final bool posted;
  final bool compact;
  final bool downloading;
  final bool posting;
  final VoidCallback onHistory;
  final VoidCallback onDownload;
  final VoidCallback onPost;

  @override
  Widget build(BuildContext context) {
    // По левому краю колонки: «История» и «Скачать» в каждой строке на одних местах,
    // «Провести» третьей — только у ожидающих. По правому краю кнопки строк с двумя и тремя
    // действиями не стояли бы друг под другом.
    return Row(
      mainAxisAlignment: MainAxisAlignment.start,
      children: [
        NeumorphicIconButton(
          icon: Icons.schedule,
          tooltip: t.portal.documents.historyTitle,
          onPressed: onHistory,
        ),
        AppBoxes.kWidth12,
        if (compact)
          NeumorphicIconButton(
            icon: Icons.download,
            tooltip: t.portal.documents.download,
            busy: downloading,
            onPressed: onDownload,
          )
        else
          NeumorphicTextButton(
            label: t.portal.documents.xlsx,
            icon: Icons.download,
            busy: downloading,
            onPressed: onDownload,
          ),
        if (!posted) ...[
          AppBoxes.kWidth12,
          if (compact)
            NeumorphicIconButton(
              icon: Icons.check,
              tooltip: t.portal.documents.post,
              busy: posting,
              onPressed: onPost,
            )
          else
            NeumorphicTextButton(
              label: t.portal.documents.post,
              busy: posting,
              onPressed: onPost,
            ),
        ],
      ],
    );
  }
}
