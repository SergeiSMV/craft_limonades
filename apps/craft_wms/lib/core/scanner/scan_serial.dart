import 'package:talker_flutter/talker_flutter.dart';

import '../di/injection.dart';
import '../utils/serial_lock.dart';

/// Сканы экрана - строго по одному, в порядке прихода, со временем каждого в журнале
/// (ADHOC-70, приём сборки из ADHOC-63).
///
/// Что: [run] ставит обработку скана в очередь экрана; следующий скан начинается, когда
/// закончился предыдущий.
/// Зачем: марки сканируют подряд быстрее, чем экран успевает разобрать скан (база терминала,
/// справочники). Без очереди два скана обрабатывались одновременно и видели сеанс без строки
/// друг друга - проверки «уже взята» и «другое место» могли не сработать.
/// Как: [SerialLock]; ошибка обработки пишется в журнал и следующий скан не останавливает;
/// время скана и ожидания в очереди - строкой «<экран>: скан обработан за N мс».
class ScanSerial {
  ScanSerial(this.screen);

  /// Название экрана для строки журнала.
  final String screen;

  final _lock = SerialLock();

  /// Обработать скан после всех ранее пришедших.
  Future<void> run(Future<void> Function() handle) async {
    final clock = Stopwatch()..start();
    var waited = 0;
    try {
      await _lock.run(() async {
        waited = clock.elapsedMilliseconds;
        await handle();
      });
    } catch (e, s) {
      getIt<Talker>().handle(e, s, '$screen: скан не обработан');
    }
    getIt<Talker>().debug(
      '$screen: скан обработан за ${clock.elapsedMilliseconds} мс '
      '(в очереди сканов $waited мс)',
    );
  }
}
