import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../data/cells_repository.dart';
import '../../../domain/cells/cell_setup.dart';
import '../../../domain/labels/beam_label.dart';
import '../settings/access_common.dart';
import '../ui/portal_button.dart';
import '../ui/portal_card.dart';
import '../ui/portal_choice.dart';
import '../ui/portal_modal.dart';
import 'cells_controller.dart';
import 'print_kind_row.dart';

/// Сохранение файла в браузере - снаружи, чтобы окно проверялось тестом без браузера.
typedef SaveFile =
    void Function({
      required Uint8List bytes,
      required String filename,
      String mime,
    });

/// Какие ячейки печатать.
enum PrintScope { all, filter, picked }

/// Окно «Печать этикеток» (ADHOC-57): какие ячейки (все, по фильтру, отмеченные) и какие из трёх
/// PDF - на большую балку, на малую, карточки на стойку; у каждого - сколько штук и листов.
///
/// Как: каждый PDF - отдельный `POST /cells/labels.pdf`, «все ячейки» - пустой список (весь
/// склад). Отказ сервера (409 - ячейки устарели, 422 - не влезает или нечего печатать) -
/// текстом под списком, окно остаётся открытым; удачные файлы уже скачаны.
Future<void> showCellsPrintDialog(
  BuildContext context,
  CellsController c,
  SaveFile save,
) => showDialog<void>(
  context: context,
  builder: (_) => _PrintDialog(c: c, save: save),
);

class _PrintDialog extends StatefulWidget {
  const _PrintDialog({required this.c, required this.save});

  final CellsController c;
  final SaveFile save;

  @override
  State<_PrintDialog> createState() => _PrintDialogState();
}

class _PrintDialogState extends State<_PrintDialog> {
  final _repo = getIt<CellsRepository>();

  late PrintScope _scope = widget.c.picked.isNotEmpty
      ? PrintScope.picked
      : PrintScope.all;
  final Set<LabelKind> _want = {...LabelKind.values};
  bool _busy = false;
  List<String> _errors = const [];

  static const _files = {
    LabelKind.large: 'labels_large.pdf',
    LabelKind.small: 'labels_small.pdf',
    LabelKind.cards: 'side_cards.pdf',
  };

  List<CellSetup> _source(PrintScope s) => switch (s) {
    PrintScope.all => widget.c.view!.cells,
    PrintScope.filter => widget.c.rows,
    PrintScope.picked => widget.c.targets,
  };

  Map<LabelKind, int> get _counts {
    final n = widget.c.view!.printCounts(_source(_scope));
    return {
      LabelKind.large: n.large,
      LabelKind.small: n.small,
      LabelKind.cards: n.cards,
    };
  }

  void setScope(PrintScope s) => setState(() {
    _scope = s;
    _errors = const [];
  });

  void toggle(LabelKind k) =>
      setState(() => _want.contains(k) ? _want.remove(k) : _want.add(k));

  /// Скачать выбранные PDF по очереди; ошибки собрать, удачные файлы сохранить.
  Future<void> download() async {
    final counts = _counts;
    final kinds = [
      for (final k in LabelKind.values)
        if (_want.contains(k) && counts[k]! > 0) k,
    ];
    if (kinds.isEmpty) {
      setState(() => _errors = [t.portal.cells.printDialog.nothing]);
      return;
    }
    final ids = _scope == PrintScope.all
        ? <String>[]
        : [for (final x in _source(_scope)) x.id];
    setState(() {
      _busy = true;
      _errors = const [];
    });
    final errors = <String>[];
    for (final k in kinds) {
      final res = await _repo.labelsPdf(k, ids);
      res.fold(
        (f) => errors.add(
          t.portal.cells.printDialog.failed(
            kind: _title(k),
            message: failureText(f),
          ),
        ),
        (bytes) => widget.save(
          bytes: bytes,
          filename: _files[k]!,
          mime: 'application/pdf',
        ),
      );
    }
    if (!mounted) return;
    if (errors.isEmpty) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _busy = false;
      _errors = errors;
    });
  }

  /// Название вида PDF - им подписана ошибка, имя файла оператору ни о чём не говорит.
  static String _title(LabelKind k) {
    final s = t.portal.cells.printDialog;
    return switch (k) {
      LabelKind.large => s.large,
      LabelKind.small => s.small,
      LabelKind.cards => s.cards,
    };
  }

  /// Строка вида PDF.
  Widget _kind(
    LabelKind k,
    String title,
    String hint,
    Map<LabelKind, int> counts,
    int perSheet,
  ) => PrintKindRow(
    title: title,
    hint: hint,
    count: counts[k]!,
    perSheet: perSheet,
    selected: _want.contains(k),
    onToggle: _busy ? null : () => toggle(k),
  );

  @override
  Widget build(BuildContext context) {
    final s = t.portal.cells.printDialog;
    final counts = _counts;
    final scopeCount = {
      PrintScope.all: widget.c.view!.cells.length,
      PrintScope.filter: widget.c.rows.length,
      PrintScope.picked: widget.c.picked.length,
    };
    final scopeLabel = {
      PrintScope.all: s.scopeAll,
      PrintScope.filter: s.scopeFilter,
      PrintScope.picked: s.scopePicked,
    };
    return PortalModal(
      title: s.title,
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PortalFieldLabel(s.scope),
          Wrap(
            spacing: AppSizes.kChipSpacing,
            runSpacing: AppSizes.kChipSpacing,
            children: [
              for (final sc in PrintScope.values)
                if (sc != PrintScope.picked || widget.c.picked.isNotEmpty)
                  PortalChoice(
                    label: scopeLabel[sc]!,
                    count: scopeCount[sc],
                    selected: _scope == sc,
                    onTap: () => setScope(sc),
                  ),
            ],
          ),
          portalFieldGap,
          PortalFieldLabel(s.what),
          PortalCard(
            children: [
              _kind(
                LabelKind.large,
                s.large,
                s.largeHint,
                counts,
                BeamProfile.large.rows,
              ),
              _kind(
                LabelKind.small,
                s.small,
                s.smallHint,
                counts,
                BeamProfile.small.rows,
              ),
              _kind(
                LabelKind.cards,
                s.cards,
                s.cardsHint,
                counts,
                kSideCardsPerSheet,
              ),
            ],
          ),
          portalFieldGap,
          Text(
            s.note,
            style: RegularTextStyles().regularInter12.copyWith(
              color: AppColors.kTextMuted,
            ),
          ),
          for (final e in _errors) ...[AppBoxes.kHeight8, AccessError(e)],
        ],
      ),
      actions: [
        portalCancel(context, label: t.portal.common.close),
        PortalButton(
          label: s.download,
          icon: Icons.download,
          kind: PortalButtonKind.primary,
          busy: _busy,
          onPressed: download,
        ),
      ],
    );
  }
}
