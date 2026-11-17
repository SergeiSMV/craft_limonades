import 'package:flutter/material.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';
import '../../../data/documents_repository.dart';
import '../ui/portal_card.dart';
import 'doc_filter.dart';
import 'doc_form.dart';
import 'doc_row_actions.dart';
import 'doc_status_chip.dart';

/// Строка документа для узкого экрана (ADHOC-26, плоский стиль - ADHOC-56): то же, что строка
/// таблицы, но каждый факт своей строкой.
///
/// Слева - номер документа со статусом, операция, контрагент и время операции с подписями
/// колонок. Справа - действия иконками: история, скачать, провести (у проведённого -
/// без «Провести»).
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

  /// Действия; `null` - у должности нет права (ADHOC-50), кнопки нет.
  final VoidCallback? onDownload;
  final VoidCallback? onPost;
  final VoidCallback? onHistory;

  @override
  Widget build(BuildContext context) {
    final posted = isPosted(doc);
    final time = form.time(doc);
    final partyTitle = form.partyTitle;
    final party = partyTitle == null ? null : form.party(doc);
    final muted = RegularTextStyles().regularInter12.copyWith(
      color: AppColors.kTextSecondary,
    );
    return Padding(
      padding: AppInsets.cardRow,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: AppSizes.kChipSpacing,
                  runSpacing: AppSizes.kChipSpacing,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      form.docTitle(doc),
                      style: SemiboldTextStyles().semiboldInter13.copyWith(
                        color: posted
                            ? AppColors.kTextSecondary
                            : AppColors.kTextMain,
                      ),
                    ),
                    DocStatusChip(posted: posted),
                  ],
                ),
                AppBoxes.kHeight4,
                Text(form.operation(doc), style: muted),
                if (party != null) ...[
                  Text(
                    t.portal.documents.line(
                      label: partyTitle!,
                      value: party.main,
                    ),
                    style: muted,
                  ),
                  if (party.sub.isNotEmpty) Text(party.sub, style: muted),
                ],
                Text(
                  t.portal.documents.line(
                    label: form.timeTitle,
                    value: '${time.main} ${time.sub}',
                  ),
                  style: muted.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
          AppBoxes.kWidth8,
          DocRowActions(
            posted: posted,
            compact: true,
            downloading: downloading,
            posting: posting,
            onHistory: onHistory,
            onDownload: onDownload,
            onPost: onPost,
          ),
        ],
      ),
    );
  }
}

/// Список документов для узкого экрана - вместо таблицы: строки в одной карточке.
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
    return PortalCard(
      children: [
        for (final d in docs)
          DocCard(
            form: form,
            doc: d,
            downloading: downloading.contains(d.id),
            posting: posting.contains(d.id),
            onDownload: onDownload == null ? null : () => onDownload!(d),
            onPost: onPost == null ? null : () => onPost!(d),
            onHistory: onHistory == null ? null : () => onHistory!(d),
          ),
      ],
    );
  }
}
