import 'dart:async';

import 'package:flutter/material.dart';
import 'package:talker_flutter/talker_flutter.dart';

import '../../../../core/di/injection.dart';
import '../../../../core/error/failure.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/printer/load_unit_label.dart';
import '../../../../core/scanner/cz_code.dart';
import '../../../../core/scanner/hardware_scan_listener.dart';
import '../../../../core/scanner/scan_code.dart';
import '../../../../core/utils/serial_lock.dart';
import '../../../../core/widgets/bind_prompt_dialog.dart';
import '../../../stock/data/catalog_models.dart';
import '../../../stock/data/catalog_repository.dart';
import '../../domain/cz_intake.dart';
import '../../domain/cz_intake_hold.dart';
import '../../domain/cz_scan.dart';
import '../../domain/cz_scan_queue.dart';
import '../cz_labels.dart';

/// Прочитанный код ЧЗ, готовый лечь в приход: ответ скана, строки по товару и партии и
/// групповые упаковки.
class CzIntakeRead {
  const CzIntakeRead({
    required this.scan,
    required this.lines,
    required this.groups,
  });

  final CzScanResult scan;
  final List<CzIntakeLine> lines;
  final List<CzGroupDraft> groups;

  /// Сколько единиц (марок) прочитано.
  int get units => lines.fold<int>(0, (n, l) => n + l.marks.length);

  /// Есть ли марки с расхождением - они уйдут в «Изолятор».
  bool get hasDiscrepancy =>
      lines.any((l) => l.marks.any((m) => m.discrepancy != null));
}

/// Тексты итога чтения: у приёмки и «Ввода остатков» свои слова («принято» / «введено»).
class CzIntakeTexts {
  const CzIntakeTexts({
    required this.marksAdded,
    required this.boxAdded,
    required this.duplicate,
    required this.boxClosed,
    required this.unreadable,
    required this.discrepancy,
  });

  final String Function(int count) marksAdded;
  final String Function(int count) boxAdded;
  final String duplicate;
  final String boxClosed;
  final String Function(int count) unreadable;
  final String discrepancy;
}

/// Итог применения пачки ответов: из него складывается один снэк на пачку.
class _CzSummary {
  int marks = 0;
  final boxes = <int>[];
  bool duplicate = false;
  bool closed = false;
  int unreadable = 0;
  bool discrepancy = false;
  int offline = 0;
  final reasons = <String>{};
}

/// Чтение кодов «Честного знака» для прихода - общее для приёмки (CZ-05) и «Ввода остатков»
/// (ADHOC-46), с очередью и пачками (ADHOC-70).
///
/// Что: скан марки или короба ЧЗ сразу встаёт в очередь чтения ([CzScanQueue]) вместе с
/// коробом экрана, куда он ляжет; кладовщик сканирует дальше, не дожидаясь ответа. Ответы
/// применяются строго по одному, в порядке сканов: проверка (короб уже на складе, марка уже
/// числится, нет даты), незнакомый GTIN - привязка поиском, затем [czApply] экрана. На пачку -
/// один снэк итога.
/// Зачем общее: оба прихода читают ЧЗ одинаково, а две копии разошлись бы на первой правке.
/// Как не потерять скан под окном: пока открыто окно привязки ШК или выбор товара, экран
/// продолжает принимать коды ЧЗ (только их) и ставит в очередь - раньше они терялись, потому
/// что раздача сканов отдаёт код только верхнему экрану. Ответ окна по GTIN запоминается до
/// конца чтения: марки того же товара второй раз не спрашивают.
mixin CzIntakeScan<T extends StatefulWidget>
    on State<T>, HardwareScanListener<T> {
  /// Показать сообщение экрана.
  void snack(String text);

  /// Выбрать товар из номенклатуры (для привязки ШК незнакомого GTIN).
  Future<Good?> pickGood();

  /// Короб ЧЗ с этим кодом уже есть в этом приходе - экран его открывает.
  /// `true` - короб найден и обработан: читать код незачем.
  bool openOwnCzBox(String code);

  /// Марка или упаковка с этим ключом уже есть в приходе: повтор не читается.
  bool czAlreadyHere(String key);

  /// Короб, в который ложится скан на этом экране; `null` - россыпь.
  String? get scanBoxId;

  /// Положить прочитанное в приход экрана: короб ЧЗ - новой ГЕ, марки - в [boxId] или россыпью.
  CzIntakeAdd czApply(CzIntakeRead read, {String? boxId});

  /// Тексты итога этого прихода.
  CzIntakeTexts get czTexts;

  /// Незавершённое чтение всего прихода - из его кубита: страница прихода ждёт по нему.
  CzIntakeHold get czHold;

  /// Очередь чтения заводится первым сканом ЧЗ: экран без марок её не держит.
  CzScanQueue<String?>? _czQueueOrNull;
  StreamSubscription<List<CzQueueResult<String?>>>? _czResults;

  CzScanQueue<String?> get _czQueue {
    final existing = _czQueueOrNull;
    if (existing != null) return existing;
    final queue = CzScanQueue<String?>(getIt<CzScanRepository>());
    _czResults = queue.results.listen(_onCzResults);
    return _czQueueOrNull = queue;
  }
  final _czApply = SerialLock();
  int _czApplying = 0;

  /// Ответ окна привязки по GTIN на время чтения: товар или `null` - отказались.
  final _gtinChoice = <String, Good?>{};

  /// Открыто окно привязки ШК или выбор товара: коды ЧЗ под ним - в очередь.
  bool _czPromptOpen = false;

  /// Работа этого экрана в [czHold]: завершается, когда все его коды легли в приход.
  Completer<void>? _czWork;

  /// Ждут ответа или применяются коды ЧЗ - сменить ячейку, уйти или отправить пока нельзя.
  bool get czBusy => (_czQueueOrNull?.pending ?? 0) > 0 || _czApplying > 0;

  @override
  void dispose() {
    unawaited(_czResults?.cancel());
    _czQueueOrNull?.dispose();
    // Экран ушёл - его чтение больше не держит приход (уход ждал его через [czSettle]).
    _czWork?.complete();
    _czWork = null;
    super.dispose();
  }

  /// Под окном привязки экран не верхний, но коды ЧЗ берёт.
  @override
  bool get canAcceptScan => super.canAcceptScan || (mounted && _czPromptOpen);

  @override
  bool acceptScan(ScanCode code) {
    if (super.canAcceptScan) return super.acceptScan(code);
    final kind = code.kind;
    if (kind != ScanKind.czMark && kind != ScanKind.czBox) return false;
    czEnqueue(code.raw);
    return true;
  }

  /// Скан кода ЧЗ: свой короб открывается, повтор отсекается на месте, остальное - в очередь
  /// чтения с коробом экрана.
  void czEnqueue(String code) {
    final box = czBoxFrom(code);
    final key = box ?? czMarkFrom(code) ?? code;
    if (box != null && openOwnCzBox(box)) return;
    if (czAlreadyHere(key) || _czQueue.holds(key)) {
      snack(czTexts.duplicate);
      return;
    }
    _czQueue.add(CzQueued(code: code, key: key, target: scanBoxId));
    if (_czWork == null) {
      _czWork = Completer<void>();
      czHold.track(_czWork!.future);
    }
    snack(t.czScan.queued(count: _czQueue.pending));
  }

  /// Чтение закончилось: работа экрана снята, ответы окна привязки забыты.
  void _czMaybeIdle() {
    if (czBusy) return;
    _gtinChoice.clear();
    _czWork?.complete();
    _czWork = null;
  }

  /// Дождаться, пока все отсканированные коды ЧЗ прочитаны и легли в приход. Зовётся перед
  /// сменой ячейки, уходом с экрана и отправкой: иначе марка легла бы не туда или пропала.
  /// Возвращает, жив ли экран.
  Future<bool> czSettle() async {
    if (!czHold.busy) return mounted;
    snack(t.czScan.settling);
    await czHold.settle();
    return mounted;
  }

  /// Уйти со страницы, дочитав марки: страница короба уходит назад этим путём.
  Future<void> czLeave() async {
    if (await czSettle()) {
      if (mounted) Navigator.of(context).pop();
    }
  }

  /// Системное «назад» на странице короба - тоже через [czLeave].
  void czOnPop(bool didPop, Object? _) {
    if (!didPop) unawaited(czLeave());
  }

  /// Пачка ответов - в очередь применения: пачки не перемешиваются, окно привязки одной
  /// пачки держит следующую.
  void _onCzResults(List<CzQueueResult<String?>> batch) {
    _czApplying++;
    unawaited(
      _czApply
          .run(() => _applyBatch(batch))
          .catchError(
            (Object e, StackTrace s) =>
                getIt<Talker>().handle(e, s, 'ЧЗ: ответ не применён'),
          )
          .whenComplete(() {
            _czApplying--;
            _czMaybeIdle();
          }),
    );
  }

  /// Применить пачку по одному коду и сказать итог одним снэком.
  Future<void> _applyBatch(List<CzQueueResult<String?>> batch) async {
    final clock = Stopwatch()..start();
    final sum = _CzSummary();
    for (final r in batch) {
      if (!mounted) return;
      if (r.result.isLeft) {
        final f = r.result.left;
        if (f is NetworkFailure) {
          sum.offline++;
        } else {
          sum.reasons.add(_failureText(f));
        }
        continue;
      }
      await _applyOne(r.result.right, r.item.target, sum);
    }
    if (!mounted) return;
    final text = _summaryText(sum);
    if (text.isNotEmpty) snack(text);
    getIt<Talker>().debug(
      'ЧЗ: пачка из ${batch.length} применена за ${clock.elapsedMilliseconds} мс, '
      'ждут ответа ${_czQueue.pending}',
    );
  }

  /// Один прочитанный код: проверить, найти товары и положить.
  Future<void> _applyOne(
    CzScanResult scan,
    String? boxId,
    _CzSummary sum,
  ) async {
    final refused = _refusal(scan);
    if (refused != null) {
      if (refused.isNotEmpty) sum.reasons.add(refused);
      return;
    }
    final goods = await _goodsOf(scan, sum);
    if (goods == null || !mounted) return;
    if (czScanGaps(scan, goods).noDate) {
      sum.reasons.add(t.czScan.noDate);
      return;
    }
    final lines = czIntakeLines(scan, goods);
    if (lines.isEmpty) {
      sum.reasons.add(t.czScan.noUnits);
      return;
    }
    final read = CzIntakeRead(
      scan: scan,
      lines: lines,
      groups: czIntakeGroups(scan),
    );
    switch (czApply(read, boxId: boxId)) {
      case CzIntakeAdd.duplicate:
        sum.duplicate = true;
      case CzIntakeAdd.czBoxClosed:
        sum.closed = true;
      case CzIntakeAdd.added:
        if (scan.kind == CzCodeKind.box) {
          sum.boxes.add(read.units);
        } else {
          sum.marks += read.units;
        }
        sum.unreadable += scan.unreadable.length;
        sum.discrepancy = sum.discrepancy || read.hasDiscrepancy;
    }
  }

  /// Почему код не взять: короб уже принят на склад, марка уже числится (с местом), свой
  /// короб ЧЗ (открывается, текста нет - пустая строка). `null` - брать можно.
  String? _refusal(CzScanResult scan) {
    switch (scan.kind) {
      case CzCodeKind.box:
        if (scan.loadUnitId != null) return t.czScan.boxOnStock;
        if (openOwnCzBox(scan.code)) return '';
      case CzCodeKind.unit:
        final mark = scan.mark;
        if (mark != null) return markTakenText(mark);
      case CzCodeKind.group:
        break;
    }
    return null;
  }

  /// Почему марку не принять: где она на складе (короб, ячейка) или что с ней стало.
  String markTakenText(CzMarkInWms m) {
    if (!m.inStock) {
      return t.czScan.markWasOnStock(status: wmsMarkStatusLabel(m.status));
    }
    final place = [
      if (m.loadUnitId != null)
        t.czScan.markPlaceBox(
          code: LoadUnitLabel(m.loadUnitId!).shortCodeFormatted,
        ),
      if (m.cellAddress != null)
        t.czScan.markPlaceCell(address: m.cellAddress!)
      else
        t.czScan.markPlaceNone,
    ].join(', ');
    return t.czScan.markOnStockAt(place: place);
  }

  /// Товары справочника по GTIN скана. Известный - из справочника терминала; незнакомый -
  /// ответ окна привязки, уже данный в этом чтении, иначе окно. `null` - товара нет
  /// (причина - в итоге).
  Future<Map<String, Good>?> _goodsOf(CzScanResult scan, _CzSummary sum) async {
    final refs = <String, CzGood?>{
      if (scan.kind == CzCodeKind.unit && scan.gtin != null)
        scan.gtin!: scan.good,
      for (final l in scan.composition) l.gtin: l.good,
    };
    final names = <String, String>{
      if (scan.gtin != null) scan.gtin!: scan.productName ?? scan.code,
      for (final l in scan.composition) l.gtin: l.productName,
    };
    final catalog = getIt<CatalogRepository>();
    final goods = <String, Good>{};
    for (final e in refs.entries) {
      final ref = e.value;
      final Good? good;
      if (ref != null) {
        good = await catalog.goodById(ref.id);
        if (good == null) sum.reasons.add(t.czScan.goodNotLoaded);
      } else {
        good = _gtinChoice.containsKey(e.key)
            ? _gtinChoice[e.key]
            : _gtinChoice[e.key] = await _bindGtin(
                e.key,
                names[e.key] ?? e.key,
              );
        if (good == null) sum.reasons.add(t.czScan.bindRefused);
      }
      if (!mounted || good == null) return null;
      goods[e.key] = good;
    }
    return goods;
  }

  /// Незнакомый GTIN: спросить, выбрать товар и привязать к нему ШК из марки. Привязка уходит
  /// операцией очереди и заодно помечает товар маркируемым - поэтому товар возвращается уже
  /// маркируемым. Пока открыты окна, коды ЧЗ принимаются в очередь ([acceptScan]).
  Future<Good?> _bindGtin(String gtin, String name) async {
    final barcode = ean13FromGtin(gtin);
    _czPromptOpen = true;
    try {
      final confirmed = await showBindPromptDialog(
        context,
        title: t.czScan.bindPromptTitle,
        body: t.czScan.bindPromptBody(name: name, barcode: barcode),
        confirmLabel: t.stockListScreen.bindConfirm,
        cancelLabel: t.stockListScreen.bindCancel,
      );
      if (!confirmed || !mounted) return null;
      final good = await pickGood();
      if (good == null || !mounted) return null;
      await getIt<CatalogRepository>().bindBarcode(
        goodId: good.id,
        barcode: barcode,
        fromCzMark: true,
      );
      return good.copyWith(czMarked: true);
    } finally {
      _czPromptOpen = false;
    }
  }

  /// Один снэк на пачку: что легло, что нет и сколько ещё читается.
  String _summaryText(_CzSummary s) => [
    if (s.marks > 0) czTexts.marksAdded(s.marks),
    for (final units in s.boxes) czTexts.boxAdded(units),
    if (s.unreadable > 0) czTexts.unreadable(s.unreadable),
    if (s.discrepancy) czTexts.discrepancy,
    if (s.duplicate) czTexts.duplicate,
    if (s.closed) czTexts.boxClosed,
    ...s.reasons,
    if (s.offline > 0) t.czScan.offlineDropped(count: s.offline),
    if (_czQueue.pending > 0) t.czScan.queued(count: _czQueue.pending),
  ].join('\n');

  /// Текст отказа чтения ЧЗ: отказ сервера - его словами.
  String _failureText(Failure f) => switch (f) {
    NetworkFailure() => t.czScan.offline,
    ServerFailure(:final message?) => t.czScan.failed(reason: message),
    _ => t.czScan.failedGeneric,
  };
}
