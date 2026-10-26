import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';
import '../../../data/documents_repository.dart';
import '../common/neumorphic_icon_button.dart';
import '../common/neumorphic_plate.dart';
import 'doc_filter.dart';
import 'doc_form.dart';

/// Карточка документа для узкого экрана (ADHOC-26): то же, что строка таблицы, в три строки.
///
/// Слева — документ, контрагент полужирным, дата и время операции. Справа — действия
/// иконками: история, скачать, провести. У проведённого перед кнопками —
/// зелёная галочка, кнопки «Провести» нет: статус виден галочкой, отдельный бейдж на телефоне
/// съел бы строку.
class DocCard extends StatelessWidget {
  const DocCard({
    super.key,
    required this.form,
    required this.doc,
    required this.downloading,
    required this.posting,
    this.onDownload,
    this.onPost,
    this.onHistory,
  });

  final DocForm form;
  final PortalDoc doc;
  final bool downloading;
  final bool posting;

  /// Действия; `null` — у должности нет права (ADHOC-50), кнопки нет.
  final VoidCallback? onDownload;
  final VoidCallback? onPost;
  final VoidCallback? onHistory;

  @override
  Widget build(BuildContext context) {
    final posted = isPosted(doc);
    final time = form.time(doc);
    final party = form.partyTitle == null ? null : form.party(doc);
    return NeumorphicPlate(
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  form.cardTitle(doc),
                  style: SemiboldTextStyles().semiboldInter12.copyWith(
                    color: AppColors.kTextMuted,
                  ),
                ),
                if (party != null) ...[
                  AppBoxes.kHeight4,
                  Text(
                    party.main,
                    style: SemiboldTextStyles().semiboldInter14.copyWith(
                      color: posted
                          ? AppColors.kTextSecondary
                          : AppColors.kTextMain,
                    ),
                  ),
                ],
                AppBoxes.kHeight4,
                Text(
                  '${time.main} · ${time.sub}',
                  style: RegularTextStyles().regularInter12.copyWith(
                    color: AppColors.kTextMuted,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
          AppBoxes.kWidth12,
          if (posted) ...[
            const Icon(
              Icons.task_alt,
              color: AppColors.kGreenLime,
              size: AppSizes.kIcon28,
            ),
            AppBoxes.kWidth8,
          ],
          _actions(posted),
        ],
      ),
    );
  }

  /// Кнопки действий — прямо на плашке карточки, как в строке таблицы.
  Widget _actions(bool posted) {
    final history = onHistory;
    final download = onDownload;
    final post = onPost;
    final buttons = <Widget>[
      if (history != null)
        NeumorphicIconButton(
          icon: Icons.schedule,
          tooltip: t.portal.documents.historyTitle,
          onPressed: history,
        ),
      if (download != null)
        NeumorphicIconButton(
          icon: Icons.download,
          tooltip: t.portal.documents.download,
          busy: downloading,
          onPressed: download,
        ),
      if (!posted && post != null)
        NeumorphicIconButton(
          icon: Icons.check,
          tooltip: t.portal.documents.post,
          busy: posting,
          onPressed: post,
        ),
    ];
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < buttons.length; i++) ...[
          if (i > 0) AppBoxes.kWidth12,
          buttons[i],
        ],
      ],
    );
  }
}

/// Список карточек документов для узкого экрана — вместо таблицы.
class DocCardList extends StatelessWidget {
  const DocCardList({
    super.key,
    required this.form,
    required this.docs,
    required this.downloading,
    required this.posting,
    this.onDownload,
    this.onPost,
    this.onHistory,
  });

  final DocForm form;
  final List<PortalDoc> docs;
  final Set<String> downloading;
  final Set<String> posting;
  final ValueChanged<PortalDoc>? onDownload;
  final ValueChanged<PortalDoc>? onPost;
  final ValueChanged<PortalDoc>? onHistory;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < docs.length; i++) ...[
          if (i > 0) AppBoxes.kHeight16,
          DocCard(
            form: form,
            doc: docs[i],
            downloading: downloading.contains(docs[i].id),
            posting: posting.contains(docs[i].id),
            onDownload: onDownload == null ? null : () => onDownload!(docs[i]),
            onPost: onPost == null ? null : () => onPost!(docs[i]),
            onHistory: onHistory == null ? null : () => onHistory!(docs[i]),
          ),
        ],
      ],
    );
  }
}
