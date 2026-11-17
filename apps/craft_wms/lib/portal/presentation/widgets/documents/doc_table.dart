import 'package:flutter/material.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';
import '../../../data/documents_repository.dart';
import '../ui/portal_card.dart';
import 'doc_card.dart';
import 'doc_filter.dart';
import 'doc_form.dart';
import 'doc_row_actions.dart';
import 'doc_status_chip.dart';

/// Таблица документов в карточке (ADHOC-26, плоский стиль - ADHOC-56): «Документ», контрагент
/// (если он есть у формы), время операции, статус в 1С, действия.
///
/// Каждое поле - в своей колонке: документы сравниваются взглядом сверху вниз. Склада нет -
/// на пилоте он один.
///
/// Действия за край не уходят никогда: при нехватке места ужимаются «Документ» и контрагент
/// (до своего минимума), а уже [AppSizes.kDocTableFullActionsWidth] кнопки «.xlsx» и «Провести»
/// становятся иконками с подсказкой. Уже [AppSizes.kDocTableMinWidth] (телефон) вместо
/// таблицы - строки [DocCard] в той же карточке.
class DocTable extends StatelessWidget {
  const DocTable({
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

  /// Строки после фильтра и поиска; пусто - «Ничего не найдено».
  final List<PortalDoc> docs;

  /// id документов, по которым идёт скачивание / проведение.
  final Set<String> downloading;
  final Set<String> posting;

  /// Действия; `null` - у должности нет права (ADHOC-50), кнопки нет.
  final ValueChanged<PortalDoc>? onDownload;
  final ValueChanged<PortalDoc>? onPost;
  final ValueChanged<PortalDoc>? onHistory;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        if (width < AppSizes.kDocTableMinWidth) {
          if (docs.isEmpty) return PortalCard(children: [_notFound()]);
          return DocCardList(
            form: form,
            docs: docs,
            downloading: downloading,
            posting: posting,
            onDownload: onDownload,
            onPost: onPost,
            onHistory: onHistory,
          );
        }
        return PortalCard(
          children: [
            Padding(
              padding: AppInsets.h8,
              child: _table(width < AppSizes.kDocTableFullActionsWidth),
            ),
          ],
        );
      },
    );
  }

  /// «Ничего не найдено» - поиск и фильтр отсекли всё.
  Widget _notFound([EdgeInsets padding = AppInsets.cardRow]) => Padding(
    padding: padding,
    child: Text(
      t.portal.documents.notFound,
      style: RegularTextStyles().regularInter13.copyWith(
        color: AppColors.kTextMuted,
      ),
    ),
  );

  /// Шапка, строки и, если ничего не нашлось, - подпись под шапкой. [compact] - действия
  /// иконками.
  Widget _table(bool compact) {
    final hasParty = form.partyTitle != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Table(
          defaultVerticalAlignment: TableCellVerticalAlignment.middle,
          columnWidths: {
            // Доля остатка, но не уже минимума: MaxColumnWidth берёт большее из двух.
            0: const MaxColumnWidth(
              FixedColumnWidth(AppSizes.kColDocMin),
              FlexColumnWidth(AppSizes.kColDoc),
            ),
            if (hasParty)
              1: const MaxColumnWidth(
                FixedColumnWidth(AppSizes.kColPartyMin),
                FlexColumnWidth(AppSizes.kColParty),
              ),
            // Время и статус - по содержимому: самая широкая дата и самый широкий бейдж
            // задают колонку, текст не обрезается ни при каком шрифте и масштабе.
            (hasParty ? 2 : 1): const IntrinsicColumnWidth(),
            (hasParty ? 3 : 2): const IntrinsicColumnWidth(),
            (hasParty ? 4 : 3): const IntrinsicColumnWidth(),
          },
          children: [
            _header(hasParty),
            for (var i = 0; i < docs.length; i++)
              _row(docs[i], last: i == docs.length - 1, compact: compact),
          ],
        ),
        // Под шапкой, по краю колонок: у таблицы уже есть поля h8.
        if (docs.isEmpty) _notFound(AppInsets.tableCell),
      ],
    );
  }

  /// Шапка таблицы: мелкие приглушённые подписи, как у списка товаров, линия под ней.
  TableRow _header(bool hasParty) {
    Widget th(String text) => Padding(
      padding: AppInsets.tableHeadCell,
      child: Text(
        text,
        style: SemiboldTextStyles().semiboldInter12.copyWith(
          color: AppColors.kTextMuted,
        ),
      ),
    );
    return TableRow(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.kDivider)),
      ),
      children: [
        th(t.portal.documents.colDoc),
        if (hasParty) th(form.partyTitle!),
        th(form.timeTitle),
        th(t.portal.documents.colStatus),
        th(t.portal.documents.colActions),
      ],
    );
  }

  /// Строка документа. Проведённый - приглушён: работы по нему больше нет.
  TableRow _row(PortalDoc doc, {required bool last, required bool compact}) {
    final posted = isPosted(doc);
    return TableRow(
      decoration: last
          ? null
          : const BoxDecoration(
              border: Border(bottom: BorderSide(color: AppColors.kDivider)),
            ),
      children: [
        _cell(form.document(doc), posted),
        if (form.partyTitle != null) _cell(form.party(doc), posted),
        _cell(form.time(doc), posted, numeric: true),
        Padding(
          padding: AppInsets.tableCell,
          child: Align(
            alignment: Alignment.centerLeft,
            child: DocStatusChip(posted: posted),
          ),
        ),
        Padding(
          padding: AppInsets.tableCell,
          child: DocRowActions(
            posted: posted,
            compact: compact,
            downloading: downloading.contains(doc.id),
            posting: posting.contains(doc.id),
            onHistory: onHistory == null ? null : () => onHistory!(doc),
            onDownload: onDownload == null ? null : () => onDownload!(doc),
            onPost: onPost == null ? null : () => onPost!(doc),
          ),
        ),
      ],
    );
  }

  /// Ячейка в две строки: основная и пояснение под ней.
  Widget _cell(CellText text, bool posted, {bool numeric = false}) {
    // Цифры одинаковой ширины: даты и время в колонке стоят ровно друг под другом.
    final figures = numeric ? const [FontFeature.tabularFigures()] : null;
    final main = posted || numeric
        ? RegularTextStyles().regularInter13.copyWith(
            color: AppColors.kTextSecondary,
          )
        : SemiboldTextStyles().semiboldInter13.copyWith(
            color: AppColors.kTextMain,
          );
    return Padding(
      padding: AppInsets.tableCell,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(text.main, style: main.copyWith(fontFeatures: figures)),
          if (text.sub.isNotEmpty)
            Text(
              text.sub,
              style: RegularTextStyles().regularInter12.copyWith(
                color: AppColors.kTextMuted,
                fontFeatures: figures,
              ),
            ),
        ],
      ),
    );
  }
}
