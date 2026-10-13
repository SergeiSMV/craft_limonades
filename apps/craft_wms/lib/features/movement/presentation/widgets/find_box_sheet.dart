import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';
import '../../../../core/widgets/search_field.dart';
import '../../../contents/domain/contents_entities.dart';
import 'move_format.dart';

/// Раздел результатов поиска короба: заголовок и короба под ним.
typedef BoxSection = (String title, List<LoadUnitView> boxes);

/// Найти короб без скана — ярлык испорчен или не читается (P6-04).
///
/// Одно поле: код с ярлыка (8 знаков под QR — их обычно видно и при испорченном QR) или адрес
/// ячейки, если ярлык не читается совсем, — тогда показываются короба этой ячейки. Поиск делает
/// экран ([search]): он знает, где искать — сервер, снимок, справочник ячеек.
Future<LoadUnitView?> showFindBoxSheet(
  BuildContext context, {
  required Future<List<BoxSection>> Function(String query) search,
}) => showModalBottomSheet<LoadUnitView>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  backgroundColor: AppColors.kNeumorphicBg,
  constraints: BoxConstraints(
    maxHeight: MediaQuery.of(context).size.height * 0.95,
  ),
  builder: (_) => _FindBoxSheet(search: search),
);

class _FindBoxSheet extends StatefulWidget {
  const _FindBoxSheet({required this.search});

  final Future<List<BoxSection>> Function(String query) search;

  @override
  State<_FindBoxSheet> createState() => _FindBoxSheetState();
}

class _FindBoxSheetState extends State<_FindBoxSheet> {
  final _controller = TextEditingController();
  Timer? _debounce;
  List<BoxSection>? _sections;
  bool _busy = false;

  /// Номер запроса: ответ устаревшего поиска не должен перезаписать свежий.
  int _seq = 0;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  /// Ввод изменился — искать с паузой, а не на каждый символ.
  void onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () => run(value));
  }

  /// Очистить поле и результаты.
  void onClear() {
    _debounce?.cancel();
    _controller.clear();
    setState(() => _sections = null);
  }

  /// Выполнить поиск по запросу.
  Future<void> run(String value) async {
    _debounce?.cancel();
    final query = value.trim();
    final seq = ++_seq;
    if (query.isEmpty) {
      setState(() => _sections = null);
      return;
    }
    setState(() => _busy = true);
    final found = await widget.search(query);
    if (!mounted || seq != _seq) return;
    setState(() {
      _busy = false;
      _sections = found;
    });
  }

  @override
  Widget build(BuildContext context) {
    final muted = RegularTextStyles().regularInter12.copyWith(
      color: AppColors.kTextMuted,
    );
    final sections = _sections;
    return Padding(
      padding:
          AppInsets.h8 +
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            t.movement.findBoxTitle,
            style: SemiboldTextStyles().semiboldInter16,
          ),
          AppBoxes.kHeight8,
          SearchField(
            hintText: t.movement.findBoxHint,
            controller: _controller,
            onChanged: onChanged,
            onSubmitted: run,
            onClear: onClear,
          ),
          AppBoxes.kHeight8,
          Text(t.movement.findBoxHelp, style: muted),
          AppBoxes.kHeight8,
          if (_busy) const LinearProgressIndicator(),
          if (sections != null && sections.every((s) => s.$2.isEmpty))
            Padding(
              padding: AppInsets.v16,
              child: Text(t.movement.findBoxEmpty, style: muted),
            ),
          if (sections != null)
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final (title, boxes) in sections)
                    if (boxes.isNotEmpty) ...[
                      Padding(
                        padding: AppInsets.top8,
                        child: Text(
                          title,
                          style: SemiboldTextStyles().semiboldInter14,
                        ),
                      ),
                      for (final b in boxes)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          leading: Icon(
                            MdiIcons.packageVariantClosed,
                            size: AppSizes.kIcon24,
                            color: AppColors.kPrimary,
                          ),
                          title: Text(
                            t.movement.findBoxLine(
                              code: boxCode(b.id),
                              cell:
                                  b.cellAddress ?? t.movement.findBoxNotPlaced,
                              count: b.lines.length,
                            ),
                            style: RegularTextStyles().regularInter14,
                          ),
                          onTap: () => Navigator.of(context).pop(b),
                        ),
                    ],
                ],
              ),
            ),
          AppBoxes.kHeight16,
        ],
      ),
    );
  }
}
