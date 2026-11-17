import 'package:flutter/services.dart';
import 'package:injectable/injectable.dart';

import 'printer_device.dart';
import 'printer_transport.dart';

/// Транспорт поверх платформенного канала к нативному мосту (P4-05).
///
/// Как: все вызовы уходят в `PrinterBridge.kt`, который держит RFCOMM-сокет. Ошибки канала
/// переводятся в [PrinterFailure] здесь, у границы платформы: выше по слоям о `PlatformException`
/// знать незачем, а код ошибки нужен - по нему экран решает, предлагать человеку настройки
/// или кнопку «повторить».
@LazySingleton(as: PrinterTransport)
class BluetoothPrinterTransport implements PrinterTransport {
  const BluetoothPrinterTransport();

  static const MethodChannel _channel = MethodChannel('craft_wms/printer');
  static const EventChannel _discovery = EventChannel(
    'craft_wms/printer/discovery',
  );

  @override
  Future<PrinterStatus> status() async {
    final raw = await _invoke<Map<Object?, Object?>>('status');
    return raw == null ? PrinterStatus.none : PrinterStatus.fromMap(raw);
  }

  @override
  Future<List<PrinterDevice>> bondedDevices() async {
    final raw = await _invoke<List<Object?>>('bonded');
    return (raw ?? const [])
        .whereType<Map<Object?, Object?>>()
        .map(PrinterDevice.fromMap)
        .toList();
  }

  @override
  Stream<PrinterDevice> discover() => _discovery
      .receiveBroadcastStream()
      .handleError(_rethrowAsFailure)
      .where((event) => event is Map)
      .map((event) => PrinterDevice.fromMap(event as Map<Object?, Object?>));

  @override
  Future<void> bond(String address) =>
      _invoke<void>('bond', {'address': address});

  @override
  Future<void> connect(String address) =>
      _invoke<void>('connect', {'address': address});

  @override
  Future<void> write(List<int> bytes) =>
      // Uint8List, а не List<int>: канал передаёт его как байтовый буфер без поэлементной
      // упаковки, и это ровно то, что ждёт нативная сторона.
      _invoke<void>('write', {'bytes': Uint8List.fromList(bytes)});

  @override
  Future<void> disconnect() => _invoke<void>('disconnect');

  @override
  Future<void> openLocationSettings() => _invoke<void>('openLocationSettings');

  /// Вызов канала с переводом платформенной ошибки в доменную.
  Future<T?> _invoke<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      throw _failure(e);
    } on MissingPluginException {
      throw const PrinterFailure(
        PrinterFailureKind.unsupported,
        'Печать недоступна на этой платформе',
      );
    }
  }

  /// Ошибка из потока обнаружения приходит тем же путём, что и из методов.
  Never _rethrowAsFailure(Object error, StackTrace stack) {
    if (error is PlatformException) throw _failure(error);
    Error.throwWithStackTrace(error, stack);
  }

  PrinterFailure _failure(PlatformException e) =>
      PrinterFailure(switch (e.code) {
        'permission' => PrinterFailureKind.permission,
        'unsupported' => PrinterFailureKind.unsupported,
        'bluetooth_off' => PrinterFailureKind.bluetoothOff,
        'location_off' => PrinterFailureKind.locationOff,
        _ => PrinterFailureKind.io,
      }, e.message ?? e.code);
}
