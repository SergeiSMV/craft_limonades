import 'package:flutter/material.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/error/failure.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/sync/data_versions.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/utils/date_time_format.dart';
import '../../../../core/widgets/data_versions_listener.dart';
import '../../../data/web_download.dart';
import '../../../domain/picking/picking_order.dart';
import '../picking/picking_order_dialog.dart';
import '../picking/picking_order_table.dart';
import '../picking/registry_load_dialog.dart';
import '../settings/access_common.dart';
import '../ui/portal_button.dart';
import '../ui/portal_card.dart';
import '../ui/portal_date_picker.dart';
import '../ui/portal_list_page.dart';

/// Вкладка «Сборка-отгрузка» (P8-02, P8-03): заказы реестра 1С за дату накладной.
///
/// Что: календарь (по умолчанию завтра — сборка идёт «сегодня на завтра»), список заказов со
/// статусом WMS, окно деталей по нажатию, загрузка реестра и выгрузка Excel даты.
/// Как: список перечитывается, когда на сервере меняется сборка (ADHOC-60): кладовщик берёт и
/// собирает заказ на ТСД — статус и факт в списке обновляются при ближайшем ответе сервера.
/// После загрузки реестра календарь переходит на дату его накладных.
class PickingTab extends StatefulWidget {
  const PickingTab({
    super.key,
    required this.canView,
    required this.canLoad,
    required this.canDownload,
    required this.canRelease,
  });

  /// Смотреть заказы и детали (или снимать с исполнителя — без просмотра не снять).
  final bool canView;

  /// Загружать реестр; без права кнопки нет.
  final bool canLoad;

  /// Выгружать Excel.
  final bool canDownload;

  /// Снимать заказ с исполнителя — кнопка в окне деталей.
  final bool canRelease;

  @override
  State<PickingTab> createState() => _PickingTabState();
}

class _PickingTabState extends State<PickingTab> {
  final _repo = getIt<PickingOrdersRepository>();

  /// Дата накладной; по умолчанию — завтра.
  late DateTime _date = _tomorrow();

  bool _loading = true;
  Failure? _error;
  List<PickingOrderSummary> _orders = const [];
  bool _downloading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  static DateTime _tomorrow() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day + 1);
  }

  /// Загрузить заказы даты. [quiet] — перечитывание по версиям данных: список остаётся на
  /// экране до ответа, ошибка его не подменяет.
  Future<void> _load({bool quiet = false}) async {
    if (!widget.canView) {
      setState(() => _loading = false);
      return;
    }
    final date = _date;
    if (!quiet) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    final res = await _repo.orders(date);
    // Ответ по прошлой дате, пока оператор уже выбрал другую, — не показываем.
    if (!mounted || date != _date || (quiet && res.isLeft)) return;
    setState(() {
      _loading = false;
      res.fold((f) => _error = f, (list) {
        _orders = list;
        _error = null;
      });
    });
  }

  /// Сборка изменилась на сервере (ADHOC-60): тихо перечитать.
  void _onDataChanged() => _load(quiet: true);

  /// Выбрать дату накладной в календаре.
  Future<void> _pickDate() async {
    final picked = await showPortalDatePicker(
      context,
      title: t.portal.picking.dateTitle,
      initial: _date,
      first: DateTime(_date.year - 1),
      last: DateTime(_date.year + 1, 12, 31),
    );
    if (picked == null || !mounted || picked == _date) return;
    setState(() => _date = picked);
    _load();
  }

  /// Загрузить реестр; после загрузки — на дату его накладных.
  Future<void> _openLoad() async {
    final res = await showRegistryLoadDialog(context);
    if (res == null || !mounted) return;
    setState(() => _date = res.date);
    _load();
  }

  /// Открыть окно деталей заказа; после закрытия список перечитывается (заказ могли снять).
  Future<void> _open(PickingOrderSummary order) async {
    await showPickingOrderDialog(
      context,
      order: order,
      canRelease: widget.canRelease,
    );
    if (mounted) _load(quiet: true);
  }

  /// Выгрузить Excel всех заказов даты — простое скачивание.
  Future<void> _download() async {
    if (_downloading) return;
    setState(() => _downloading = true);
    final res = await _repo.export(_date);
    if (!mounted) return;
    setState(() => _downloading = false);
    res.fold(
      (f) => _snack(t.portal.picking.error(message: pickingErrorText(f))),
      (file) {
        downloadBytes(
          bytes: file.bytes,
          filename: file.filename,
          mime:
              'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        );
        _snack(t.portal.picking.downloaded);
      },
    );
  }

  /// Показать снекбар.
  void _snack(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) => DataVersionsListener(
    domains: const {DataDomain.picking},
    onChanged: _onDataChanged,
    child: PortalListPage(toolbar: _toolbar(), body: _body()),
  );

  /// Календарь слева, загрузка и выгрузка — рядом; на узком экране переносятся.
  Widget _toolbar() {
    final p = t.portal.picking;
    return Wrap(
      spacing: AppSizes.kChipSpacing,
      runSpacing: AppSizes.kChipSpacing,
      children: [
        if (widget.canView || widget.canDownload)
          PortalButton(
            label: p.dateButton(date: fullDate(_date)),
            icon: Icons.calendar_today_outlined,
            onPressed: _pickDate,
          ),
        if (widget.canDownload)
          PortalButton(
            label: p.downloadButton,
            icon: Icons.download_outlined,
            busy: _downloading,
            onPressed: _download,
          ),
        if (widget.canLoad)
          PortalButton(
            label: p.loadButton,
            icon: Icons.upload_file,
            kind: PortalButtonKind.primary,
            onPressed: _openLoad,
          ),
      ],
    );
  }

  /// Заказы даты; вместо них — загрузка, ошибка или пусто.
  Widget _body() {
    final p = t.portal.picking;
    if (!widget.canView) return _message(p.noView);
    if (_loading) return const SettingsListCard(loading: true, rows: []);
    final error = _error;
    if (error != null) {
      return PortalCard(
        children: [
          Padding(
            padding: AppInsets.cardRow,
            child: Row(
              children: [
                Expanded(
                  child: AccessError(p.error(message: pickingErrorText(error))),
                ),
                AppBoxes.kWidth8,
                PortalButton(label: p.retry, onPressed: _load),
              ],
            ),
          ),
        ],
      );
    }
    if (_orders.isEmpty) return _message(p.emptyDate(date: fullDate(_date)));
    return PickingOrderTable(orders: _orders, onOpen: _open);
  }

  /// Сообщение вместо списка — карточкой под панелью.
  Widget _message(String text) => PortalCard(
    children: [
      Padding(
        padding: AppInsets.cardRow,
        child: Text(
          text,
          style: RegularTextStyles().regularInter13.copyWith(
            color: AppColors.kTextMuted,
          ),
        ),
      ),
    ],
  );
}
