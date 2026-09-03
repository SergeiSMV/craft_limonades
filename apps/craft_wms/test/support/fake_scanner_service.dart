import 'dart:async';

import 'package:craft_wms/core/di/injection.dart';
import 'package:craft_wms/core/scanner/scan_code.dart';
import 'package:craft_wms/core/scanner/scan_event.dart';
import 'package:craft_wms/core/scanner/scan_router.dart';
import 'package:craft_wms/core/scanner/scanner_service.dart';
import 'package:talker_flutter/talker_flutter.dart';

/// Управляемый источник сканов для тестов: код подаётся вызовом [emit], без платформенного канала.
class FakeScannerService implements ScannerService {
  FakeScannerService({this.probeResult = ScannerProbe.none});

  final ScannerProbe probeResult;

  final _controller = StreamController<RawScanEvent>.broadcast();

  @override
  Stream<RawScanEvent> get rawEvents => _controller.stream;

  @override
  Stream<ScanCode> get scans => rawEvents
      .map((event) => event.scan)
      .where((scan) => scan != null)
      .cast<ScanCode>();

  @override
  Future<ScannerProbe> probe() async => probeResult;

  @override
  ScannerProbe? get lastProbe => probeResult;

  /// Подать код так, как его прислал бы драйвер сканера.
  void emit(String code, {String? symbology}) => _controller.add(
    RawScanEvent(
      action: 'android.intent.ACTION_DECODE_DATA',
      extras: {'barcode_string': code},
      code: code,
      symbology: symbology,
    ),
  );

  Future<void> dispose() => _controller.close();
}

/// Зарегистрировать источник сканов в DI вместе с раздающим их роутером.
///
/// Роутер поднимается здесь же, а не в каждом тесте: подписчики берут его из DI
/// (`HardwareScanListener`), и без него не собирается ни один экран со сканом. Регистрация
/// в одном месте держит существующие тесты в неведении о том, как устроена раздача.
FakeScannerService registerFakeScanner({
  ScannerProbe probe = ScannerProbe.none,
}) {
  if (getIt.isRegistered<ScannerService>()) {
    getIt.unregister<ScannerService>();
  }
  final fake = FakeScannerService(probeResult: probe);
  getIt.registerSingleton<ScannerService>(fake);
  if (getIt.isRegistered<ScanRouter>()) {
    getIt.unregister<ScanRouter>();
  }
  getIt.registerSingleton<ScanRouter>(ScanRouter(fake, Talker()));
  return fake;
}
