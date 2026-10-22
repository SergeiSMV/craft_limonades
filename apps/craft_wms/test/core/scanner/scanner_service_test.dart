import 'package:craft_wms/core/scanner/scanner_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';

/// Скан принимает только приложение на экране (ADHOC-39).
///
/// С приложением стенда рядом с боевым сканер Urovo рассылает код обоим, а приёмник канала
/// живёт и в фоне: без фильтра скан в одном доставался бы и другому.
void main() {
  const channel = EventChannel('craft_wms/scanner/scans');

  testWidgets('в фоне скан отбрасывается, на экране — принимается', (
    tester,
  ) async {
    // Мост есть только на Android; переопределение снимается в конце тела — фреймворк
    // проверяет отладочные переменные до tearDown.
    debugDefaultTargetPlatformOverride = TargetPlatform.android;

    late MockStreamHandlerEventSink sink;
    tester.binding.defaultBinaryMessenger.setMockStreamHandler(
      channel,
      MockStreamHandler.inline(
        onListen: (_, events) {
          sink = events;
        },
      ),
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockStreamHandler(
        channel,
        null,
      ),
    );

    final received = <String>[];
    final sub = HardwareScannerService(
      Talker(),
    ).scans.listen((scan) => received.add(scan.raw));
    addTearDown(sub.cancel);
    await tester.pump();

    Map<String, Object?> scan(String code) => {
      'action': 'android.intent.ACTION_DECODE_DATA',
      'code': code,
    };

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    sink.success(scan('4601234567893'));
    await tester.pump();

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    sink.success(scan('4601234567800'));
    await tester.pump();

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    sink.success(scan('4601234567817'));
    await tester.pump();

    debugDefaultTargetPlatformOverride = null;
    expect(received, ['4601234567893', '4601234567817']);
  });
}
