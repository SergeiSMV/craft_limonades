import 'package:flutter/material.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/gen/strings.g.dart';
import '../ui/portal_button.dart';

/// Действия строки таблицы документов (ADHOC-26, плоский стиль — ADHOC-56): история, скачать
/// .xlsx, провести — у проведённого кнопки «Провести» нет. [compact] — скачивание и
/// проведение иконками с подсказкой вместо подписей: так ряд помещается на ширине ноутбука;
/// на телефоне — тоже иконками.
class DocRowActions extends StatelessWidget {
  const DocRowActions({
    super.key,
    required this.posted,
    required this.compact,
    required this.downloading,
    required this.posting,
    this.onHistory,
    this.onDownload,
    this.onPost,
  });

  final bool posted;
  final bool compact;
  final bool downloading;
  final bool posting;

  /// Действия; `null` — у должности нет права (ADHOC-50), кнопки нет.
  final VoidCallback? onHistory;
  final VoidCallback? onDownload;
  final VoidCallback? onPost;

  @override
  Widget build(BuildContext context) {
    // По левому краю колонки: «История» и «Скачать» в каждой строке на одних местах,
    // «Провести» третьей — только у ожидающих. По правому краю кнопки строк с двумя и тремя
    // действиями не стояли бы друг под другом.
    final history = onHistory;
    final download = onDownload;
    final post = onPost;
    final buttons = <Widget>[
      if (history != null)
        PortalIconButton(
          icon: Icons.schedule,
          tooltip: t.portal.documents.historyTitle,
          onPressed: history,
        ),
      if (download != null)
        compact
            ? PortalIconButton(
                icon: Icons.download,
                tooltip: t.portal.documents.download,
                busy: downloading,
                onPressed: download,
              )
            : PortalButton(
                label: t.portal.documents.xlsx,
                icon: Icons.download,
                busy: downloading,
                onPressed: download,
              ),
      if (!posted && post != null)
        compact
            ? PortalIconButton(
                icon: Icons.check,
                tooltip: t.portal.documents.post,
                busy: posting,
                onPressed: post,
              )
            : PortalButton(
                label: t.portal.documents.post,
                busy: posting,
                onPressed: post,
              ),
      // Иконками у проведённого — пустое место вместо «Провести»: в узком списке действия
      // прижаты вправо, и «История» со «Скачать» иначе съезжали бы в строках проведённых.
      if (posted && post != null && compact)
        const SizedBox.square(dimension: AppSizes.kControlHeight),
    ];
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < buttons.length; i++) ...[
          if (i > 0) AppBoxes.kWidth8,
          buttons[i],
        ],
      ],
    );
  }
}
