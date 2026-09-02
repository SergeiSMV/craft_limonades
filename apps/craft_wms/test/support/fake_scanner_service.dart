import 'dart:async';

import 'package:craft_wms/core/di/injection.dart';
import 'package:craft_wms/core/scanner/scan_code.dart';
import 'package:craft_wms/core/scanner/scan_event.dart';
import 'package:craft_wms/core/scanner/scanner_service.dart';

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

/// Зарегистрировать источник сканов в DI: экраны берут [ScannerService] оттуда.
FakeScannerService registerFakeScanner({
  ScannerProbe probe = ScannerProbe.none,
}) {
  if (getIt.isRegistered<ScannerService>()) {
    getIt.unregister<ScannerService>();
  }
  final fake = FakeScannerService(probeResult: probe);
  getIt.registerSingleton<ScannerService>(fake);
  return fake;
}
