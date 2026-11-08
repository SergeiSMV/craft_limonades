import 'package:flutter/material.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/utils/date_time_format.dart';
import '../picking/registry_load_dialog.dart';
import '../ui/portal_button.dart';
import '../ui/portal_card.dart';
import '../ui/portal_list_page.dart';

/// Вкладка «Сборка-отгрузка» (P8-02): загрузка «Реестра» 1С с предпросмотром. Список заказов
/// по дате с календарём, окно деталей и выгрузка Excel — P8-03.
class PickingTab extends StatefulWidget {
  const PickingTab({super.key, required this.canLoad});

  /// Право «загружать реестр»; без него кнопки загрузки нет.
  final bool canLoad;

  @override
  State<PickingTab> createState() => _PickingTabState();
}

class _PickingTabState extends State<PickingTab> {
  /// Дата последнего загруженного в этом окне реестра — подтверждение под кнопкой.
  DateTime? _lastLoaded;

  Future<void> _openLoad() async {
    final res = await showRegistryLoadDialog(context);
    if (res == null || !mounted) return;
    setState(() => _lastLoaded = res.date);
  }

  @override
  Widget build(BuildContext context) {
    final p = t.portal.picking;
    final last = _lastLoaded;
    return PortalListPage(
      toolbar: Align(
        alignment: Alignment.centerLeft,
        child: widget.canLoad
            ? PortalButton(
                label: p.loadButton,
                icon: Icons.upload_file,
                kind: PortalButtonKind.primary,
                onPressed: _openLoad,
              )
            : const SizedBox.shrink(),
      ),
      body: PortalCard(
        children: [
          Padding(
            padding: AppInsets.cardRow,
            child: Text(
              last == null ? p.empty : p.lastLoad(date: fullDate(last)),
              style: RegularTextStyles().regularInter13.copyWith(
                color: AppColors.kTextMuted,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
