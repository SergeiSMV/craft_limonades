import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';

import '../../../../core/di/injection.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/load_unit/load_unit_id_generator.dart';
import '../../../../core/printer/label_geometry.dart';
import '../../../../core/printer/label_language.dart';
import '../../../../core/printer/printer_device.dart';
import '../../../../core/printer/printer_service.dart';
import '../widgets/printer_probe/label_geometry_card.dart';
import '../widgets/printer_probe/printer_device_tile.dart';
import '../widgets/printer_probe/printer_status_card.dart';

/// Служебный экран наладки принтера этикеток (P4-05).
///
/// Что: показывает состояние Bluetooth, даёт выбрать принтер из спаренных или найти новый,
///      переключить язык команд и напечатать тестовую этикетку.
/// Зачем: какой язык примет конкретный экземпляр принтера, по документации не выясняется —
///      на дисплее XP-P323B заводской режим обозначен `EZD`, то есть набор эмуляций Zebra,
///      в котором TSPL не упомянут. Этот экран и есть инструмент такой проверки: выбрал язык,
///      нажал печать, посмотрел, что вышло из принтера.
/// Как: всё через [PrinterService]; поиск живёт ровно на время подписки.
///
/// Оформление намеренно служебное (стандартный Material, как у экрана сканера): это инструмент
/// наладки, а не рабочий экран кладовщика. Печать из потока приёмки появится в `P4-06`.
@RoutePage()
class PrinterProbePage extends StatefulWidget {
  const PrinterProbePage({super.key});

  @override
  State<PrinterProbePage> createState() => _PrinterProbePageState();
}

class _PrinterProbePageState extends State<PrinterProbePage> {
  final _service = getIt<PrinterService>();
  final _ids = getIt<LoadUnitIdGenerator>();

  /// Идентификатор последнего напечатанного пробного ярлыка — чтобы проверить повторную печать
  /// тем же кодом, а не новым.
  String? _lastLabelId;

  StreamSubscription<PrinterDevice>? _discovery;
  PrinterStatus _status = PrinterStatus.none;
  PrinterDevice? _selected;
  List<PrinterDevice> _bonded = const [];
  final List<PrinterDevice> _found = [];
  LabelLanguage _language = kLabelLanguages.first;
  LabelGeometry _geometry = LabelGeometry.fallback;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  @override
  void dispose() {
    _discovery?.cancel();
    super.dispose();
  }

  /// Перечитать состояние: что с Bluetooth, что выбрано, какие устройства спарены.
  Future<void> _refresh() async {
    final status = await _service.status();
    final selected = await _service.selected();
    final language = await _service.language();
    final geometry = await _service.geometry();
    var bonded = const <PrinterDevice>[];
    if (status.enabled) {
      bonded = await _fetch(_service.bondedDevices) ?? const [];
    }
    if (!mounted) return;
    setState(() {
      _status = status;
      _selected = selected;
      _language = language;
      _geometry = geometry;
      _bonded = bonded;
    });
  }

  /// Запомнить принтер и сразу подключиться к нему.
  Future<void> selectDevice(PrinterDevice device) async {
    await _run(() => _service.select(device));
    await _refresh();
  }

  /// Забыть принтер — когда его заменили на другой.
  Future<void> forgetDevice() async {
    await _run(_service.forget);
    await _refresh();
  }

  /// Сменить язык команд. Он запоминается: подбор языка делается один раз на модель принтера.
  Future<void> changeLanguage(LabelLanguage value) async {
    await _service.selectLanguage(value);
    if (mounted) setState(() => _language = value);
  }

  /// Запомнить размер рулона. Он объявляется принтеру с каждой печатью, поэтому применяется
  /// сразу — отдельного «сохранить и перезапустить» не нужно.
  Future<void> changeGeometry(LabelGeometry value) async {
    await _service.saveGeometry(value);
    if (mounted) setState(() => _geometry = value);
  }

  /// Напечатать пробный ярлык ГЕ. Первый тап печатает новый код, следующие — тот же:
  /// так проверяется и печать при создании короба, и повторная печать испорченной наклейки.
  Future<void> printLoadUnitLabel({required bool reprint}) async {
    final id = reprint ? _lastLabelId ?? _ids.newId() : _ids.newId();
    setState(() => _busy = true);
    final sent = await _run(() => _service.printLoadUnitLabel(id));
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (sent) _lastLabelId = id;
    });
    if (sent) _snack(t.printerProbe.printed);
  }

  /// Напечатать диагностическую этикетку кириллицы.
  Future<void> printCyrillicProbe() async {
    setState(() => _busy = true);
    final sent = await _run(() => _service.printCyrillicProbe(_language));
    if (!mounted) return;
    setState(() => _busy = false);
    if (sent) _snack(t.printerProbe.printed);
  }

  /// Калибровать датчик промежутка под заправленный рулон.
  Future<void> calibrate() async {
    setState(() => _busy = true);
    final sent = await _run(() => _service.calibrate(_language));
    if (!mounted) return;
    setState(() => _busy = false);
    if (sent) _snack(t.printerProbe.calibrated);
  }

  /// Начать или остановить поиск новых устройств.
  Future<void> toggleSearch() async {
    if (_discovery != null) {
      await _discovery?.cancel();
      if (mounted) setState(() => _discovery = null);
      return;
    }
    setState(_found.clear);
    try {
      final subscription = _service.discover().listen(
        _onFound,
        onError: (Object e) {
          _report(e);
          if (mounted) setState(() => _discovery = null);
        },
        onDone: () {
          if (mounted) setState(() => _discovery = null);
          _snack(t.printerProbe.searchDone);
        },
      );
      setState(() => _discovery = subscription);
    } catch (e) {
      _report(e);
    }
  }

  /// Найденное устройство — в список, без дублей: обнаружение повторяет одно устройство.
  void _onFound(PrinterDevice device) {
    if (!mounted) return;
    if (_found.any((d) => d.address == device.address)) return;
    setState(() => _found.add(device));
  }

  /// Напечатать тестовую этикетку выбранным языком — критерий готовности задачи.
  Future<void> printTest() async {
    setState(() => _busy = true);
    final printed = await _run(() => _service.printTestLabel(_language));
    if (!mounted) return;
    setState(() => _busy = false);
    if (printed) _snack(t.printerProbe.printed);
    await _refresh();
  }

  /// Выполняет действие, показывая отказ человеку вместо падения. `false` — не удалось.
  ///
  /// Отдельно от [_fetch], потому что у действия нет результата, и `null` как признак неудачи
  /// пришлось бы изображать через `void?` — тип, по которому ничего не проверишь.
  Future<bool> _run(Future<void> Function() action) async {
    try {
      await action();
      return true;
    } catch (e) {
      _report(e);
      return false;
    }
  }

  /// Читает значение, показывая отказ человеку вместо падения. `null` — не удалось.
  Future<T?> _fetch<T>(Future<T> Function() action) async {
    try {
      return await action();
    } catch (e) {
      _report(e);
      return null;
    }
  }

  void _report(Object error) {
    final message = error is PrinterFailure ? error.message : '$error';
    _snack(message);
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final searching = _discovery != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(t.printerProbe.title),
        actions: [
          IconButton(
            tooltip: t.printerProbe.status,
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          PrinterStatusCard(status: _status, selected: _selected),
          const SizedBox(height: 12),
          _languageSelector(),
          const SizedBox(height: 12),
          LabelGeometryCard(geometry: _geometry, onChanged: changeGeometry),
          const SizedBox(height: 12),
          _actions(searching),
          const SizedBox(height: 12),
          _deviceSection(
            t.printerProbe.paired,
            _bonded,
            _bonded.isEmpty ? t.printerProbe.noPaired : null,
          ),
          if (_found.isNotEmpty || searching) ...[
            const SizedBox(height: 12),
            _deviceSection(
              t.printerProbe.found,
              _found,
              searching && _found.isEmpty ? t.printerProbe.searching : null,
            ),
          ],
          const SizedBox(height: 16),
          Text(
            t.printerProbe.hint,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  /// Переключатель языка команд: какой из них примет принтер, решает печать.
  Widget _languageSelector() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              t.printerProbe.language,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            SegmentedButton<String>(
              segments: [
                for (final language in kLabelLanguages)
                  ButtonSegment<String>(
                    value: language.id,
                    label: Text(language.title),
                  ),
              ],
              selected: {_language.id},
              onSelectionChanged: (ids) {
                final picked = labelLanguageById(ids.first);
                if (picked != null) changeLanguage(picked);
              },
            ),
          ],
        ),
      ),
    );
  }

  /// Кнопки: печать тестовой этикетки, поиск устройств, сброс выбранного принтера.
  Widget _actions(bool searching) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        FilledButton.icon(
          onPressed: _busy || _selected == null ? null : printTest,
          icon: const Icon(Icons.print),
          label: Text(
            _busy ? t.printerProbe.printing : t.printerProbe.printTest,
          ),
        ),
        FilledButton.tonalIcon(
          onPressed: _busy || _selected == null
              ? null
              : () => printLoadUnitLabel(reprint: false),
          icon: const Icon(Icons.qr_code_2),
          label: Text(t.printerProbe.loadUnitLabel),
        ),
        if (_lastLabelId != null)
          OutlinedButton.icon(
            onPressed: _busy ? null : () => printLoadUnitLabel(reprint: true),
            icon: const Icon(Icons.copy),
            label: Text(t.printerProbe.loadUnitReprint),
          ),
        OutlinedButton.icon(
          onPressed: _busy || _selected == null ? null : printCyrillicProbe,
          icon: const Icon(Icons.translate),
          label: Text(t.printerProbe.cyrillicProbe),
        ),
        OutlinedButton.icon(
          onPressed: _busy || _selected == null ? null : calibrate,
          icon: const Icon(Icons.straighten),
          label: Text(
            _busy ? t.printerProbe.calibrating : t.printerProbe.calibrate,
          ),
        ),
        OutlinedButton.icon(
          onPressed: _status.enabled ? toggleSearch : null,
          icon: Icon(searching ? Icons.stop : Icons.search),
          label: Text(
            searching ? t.printerProbe.stopSearch : t.printerProbe.search,
          ),
        ),
        if (_selected != null)
          TextButton(
            onPressed: forgetDevice,
            child: Text(t.printerProbe.forget),
          ),
      ],
    );
  }

  /// Секция со списком устройств; [empty] — что показать, когда список пуст.
  Widget _deviceSection(
    String title,
    List<PrinterDevice> devices,
    String? empty,
  ) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(title, style: theme.textTheme.titleSmall),
            ),
            if (empty != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(empty, style: theme.textTheme.bodySmall),
              ),
            for (final device in devices)
              PrinterDeviceTile(
                device: device,
                selected: device.address == _selected?.address,
                onTap: () => selectDevice(device),
              ),
          ],
        ),
      ),
    );
  }
}
