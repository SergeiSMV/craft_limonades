import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:injectable/injectable.dart';
import 'package:talker_flutter/talker_flutter.dart';

import 'scan_code.dart';
import 'scan_event.dart';

/// Источник кодов с аппаратного сканера.
///
/// Абстракция, а не прямое обращение к платформенному каналу: экраны не должны знать, откуда
/// пришёл код. Вторая реализация (камера) подключается сюда же, без правок экранов.
abstract interface class ScannerService {
  /// Сырые события драйвера — для диагностики.
  Stream<RawScanEvent> get rawEvents;

  /// Распознанные коды — то, с чем работают экраны.
  Stream<ScanCode> get scans;

  /// Опрос устройства: есть ли аппаратный сканер. Результат кэшируется.
  Future<ScannerProbe> probe();

  /// Результат последнего опроса, если он уже выполнен.
  ///
  /// Нужен для синхронной сборки UI: экран входа выбирает форму (скан бейджа или логин/пароль)
  /// прямо в `build`, и `Future` там дал бы мелькание одной формы поверх другой.
  ScannerProbe? get lastProbe;
}

/// Реализация поверх платформенного канала к [ScannerBridge] (Android/Urovo).
///
/// На веб-портале и в тестах канала нет: опрос отдаёт «сканера нет», поток кодов пуст —
/// приложение работает прежним клавиатурным вводом, без падений и заглушек на местах вызова.
@LazySingleton(as: ScannerService)
class HardwareScannerService implements ScannerService {
  HardwareScannerService(this._talker);

  static const MethodChannel _method = MethodChannel('craft_wms/scanner');
  static const EventChannel _events = EventChannel('craft_wms/scanner/scans');

  final Talker _talker;

  /// Кэш потока: подписка на канал одна на всё приложение.
  Stream<RawScanEvent>? _rawEvents;

  ScannerProbe? _probe;

  @override
  ScannerProbe? get lastProbe => _probe;

  /// Платформа, на которой мост вообще существует.
  bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  Stream<RawScanEvent> get rawEvents {
    if (!_supported) return const Stream<RawScanEvent>.empty();
    // Ошибку канала гасим в лог и НЕ роняем поток: обрыв сканера не должен убивать экран,
    // на котором кладовщик стоит с непросчитанной ячейкой.
    return _rawEvents ??= _events
        .receiveBroadcastStream()
        .where((_) => _onScreen)
        .map(
          (event) => RawScanEvent.fromChannel(event as Map<Object?, Object?>),
        )
        .handleError(
          (Object error, StackTrace stack) =>
              _talker.handle(error, stack, 'Поток сканера'),
        );
  }

  /// Приложение на экране (ADHOC-39).
  ///
  /// Сканер Urovo рассылает код всем приложениям, а приёмник канала живёт, пока жив движок, —
  /// и в фоне тоже. Пока приложение было одно, это не мешало; с приложением стенда рядом скан
  /// в одном доставался бы и другому, висящему в фоне на экране, который ждёт скан. Поэтому
  /// код принимает только приложение на экране. `null` — состояние ещё не пришло (старт,
  /// тесты без привязки): не отсекаем.
  bool get _onScreen {
    final state = WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }

  @override
  Stream<ScanCode> get scans => rawEvents
      .map((event) => event.scan)
      .where((scan) => scan != null)
      .cast<ScanCode>();

  @override
  Future<ScannerProbe> probe() async {
    if (!_supported) return _probe = ScannerProbe.none;
    final cached = _probe;
    if (cached != null) return cached;
    try {
      final data = await _method.invokeMapMethod<Object?, Object?>('probe');
      return _probe = data == null
          ? ScannerProbe.none
          : ScannerProbe.fromChannel(data);
    } on MissingPluginException {
      // Канал не подключён (тесты, десктоп) — считаем, что аппаратного сканера нет.
      return _probe = ScannerProbe.none;
    } on PlatformException catch (error, stack) {
      _talker.handle(error, stack, 'Опрос сканера');
      return _probe = ScannerProbe.none;
    }
  }
}
