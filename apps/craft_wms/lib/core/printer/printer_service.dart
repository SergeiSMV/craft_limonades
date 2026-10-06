import 'dart:io';

import 'package:injectable/injectable.dart';
import 'package:permission_handler/permission_handler.dart';

import 'label_geometry.dart';
import 'label_language.dart';
import 'good_label.dart';
import 'load_unit_label.dart';
import 'printer_device.dart';
import 'printer_settings.dart';
import 'printer_transport.dart';

/// Печать этикеток: выбор принтера, соединение и отправка команд (P4-05).
///
/// Что: единая точка, через которую экраны печатают. Знает выбранный принтер и язык его команд,
/// поднимает соединение по необходимости.
/// Зачем: соединение держится открытым между этикетками (RFCOMM-сокет устанавливается заметно
/// долго), и решать «подключаться или нет» на каждом экране значило бы повторять эту логику
/// столько раз, сколько мест печатает.
@lazySingleton
class PrinterService {
  const PrinterService(this._transport, this._settings);

  final PrinterTransport _transport;
  final PrinterSettings _settings;

  /// Состояние Bluetooth и соединения.
  Future<PrinterStatus> status() => _transport.status();

  /// Спаренные устройства — основной путь выбора принтера.
  Future<List<PrinterDevice>> bondedDevices() async {
    await _requireConnectPermission();
    return _transport.bondedDevices();
  }

  /// Поиск новых устройств. Права спрашиваем до подписки: отказ в правах посреди потока
  /// выглядел бы как «поиск ничего не нашёл», а это разные вещи для человека.
  Stream<PrinterDevice> discover() async* {
    await _requireScanPermission();
    yield* _transport.discover();
  }

  /// Выбранный принтер, каким его помнит терминал.
  Future<PrinterDevice?> selected() async {
    final address = await _settings.address();
    if (address == null) return null;
    return PrinterDevice(address: address, name: await _settings.name() ?? '');
  }

  /// Выбранный язык команд. По умолчанию — TSPL: он заявлен основным (решение по вопросу №6),
  /// а какой язык примет конкретный экземпляр, выясняется печатью тестовой этикетки.
  Future<LabelLanguage> language() async =>
      labelLanguageById(await _settings.languageId()) ?? kLabelLanguages.first;

  /// Выбрать принтер: спарить, подключиться и — только при успехе — запомнить.
  ///
  /// Порядок именно такой. Запомни мы принтер раньше, терминал считал бы выбранным тот,
  /// с которым не удалось даже спариться, и каждая печать падала бы на нём заново.
  Future<void> select(PrinterDevice device) async {
    await _connectTo(device);
    await _settings.savePrinter(address: device.address, name: device.name);
  }

  /// Запомнить язык команд.
  Future<void> selectLanguage(LabelLanguage value) =>
      _settings.saveLanguage(value.id);

  /// Размер заправленного рулона. До первой настройки — умолчание, и это догадка:
  /// принтер не знает, что в него заправлено, пока ему не скажут.
  Future<LabelGeometry> geometry() async =>
      LabelGeometry.parse(await _settings.geometry());

  /// Запомнить размер рулона.
  Future<void> saveGeometry(LabelGeometry value) =>
      _settings.saveGeometry(value.stored);

  /// Забыть принтер — когда его заменили.
  Future<void> forget() async {
    await _transport.disconnect();
    await _settings.forgetPrinter();
  }

  /// Подключиться к выбранному принтеру. Повторный вызов на живом соединении ничего не делает.
  Future<void> connect() async {
    final device = await selected();
    if (device == null) {
      throw const PrinterFailure(PrinterFailureKind.io, 'Принтер не выбран');
    }
    await _connectTo(device);
  }

  /// Спаривание и соединение — единственное место, где они происходят.
  ///
  /// Спаривание отдельным шагом перед сокетом: неявное, которое запускает сам `connect()`,
  /// Android ведёт по упрощённому пути без запроса PIN, и принтер отвергает его отказом
  /// аутентификации. Уже спаренное устройство проходит шаг мгновенно, поэтому проверка дешёвая
  /// и нужна на случай, когда принтер убрали из спаренных в настройках Android.
  Future<void> _connectTo(PrinterDevice device) async {
    final current = await _transport.status();
    if (current.connected && current.address == device.address) return;
    await _requireConnectPermission();
    await _transport.bond(device.address);
    await _transport.connect(device.address);
  }

  Future<void> disconnect() => _transport.disconnect();

  /// Напечатать тестовую этикетку заданным языком — это и есть критерий готовности P4-05.
  ///
  /// Язык передаётся явно, а не берётся из настроек: на экране проверки человек сравнивает
  /// языки между собой, и печать «тем, что сохранено» не дала бы сравнить.
  Future<void> printTestLabel(LabelLanguage language) async =>
      printRaw(language.testLabel(await geometry()));

  /// Напечатать коробочный ярлык грузовой единицы (P4-06).
  ///
  /// Повторная печать — тот же вызов с тем же идентификатором: ярлык полностью определяется
  /// им, и «напечатать ещё раз» не нуждается ни в отдельной команде, ни в признаке повтора.
  /// Испорченную наклейку просто меняют на такую же.
  ///
  /// Язык здесь не выбирается: QR и кириллица проверены на TSPL, и печатать ярлык тем, что
  /// сейчас стоит переключателем на экране наладки, значило бы отдать рабочую операцию
  /// во власть отладочной настройки.
  ///
  /// [trialMark] — пометка пробной печати для экрана наладки (ADHOC-19); рабочая печать
  /// из приёмки её не передаёт.
  Future<void> printLoadUnitLabel(
    String loadUnitId, {
    String? trialMark,
  }) async => printRaw(
    LoadUnitLabel(loadUnitId, trialMark: trialMark).tspl(await geometry()),
  );

  /// Напечатать товарный ярлык: штрихкод и наименование (P4-08).
  ///
  /// Печать и перепечать — один и тот же вызов: ярлык полностью определяется кодом и
  /// наименованием, и испорченную наклейку меняют на такую же. Отдельного «перепечатать»
  /// не нужно ни в API, ни в интерфейсе.
  Future<void> printGoodLabel({
    required String barcode,
    required String goodName,
  }) async => printRaw(
    GoodLabel(barcode: barcode, goodName: goodName).tspl(await geometry()),
  );

  /// Напечатать координатную сетку — чтобы увидеть, где у принтера начало координат.
  Future<void> printLayoutProbe(LabelLanguage language) async =>
      printRaw(language.layoutProbe(await geometry()));

  /// Напечатать диагностическую этикетку кириллицы — какие встроенные шрифты её берут.
  ///
  /// Нужна один раз на модель принтера: по документации вопрос не решается, а от ответа
  /// зависит, печатать ли ярлык текстом или гнать его графикой (`P4-06`).
  Future<void> printCyrillicProbe(LabelLanguage language) async =>
      printRaw(language.cyrillicProbe(await geometry()));

  /// Калибровать датчик промежутка под заправленный рулон.
  ///
  /// Делается один раз на рулон. Принтер при этом прогоняет пару этикеток — это измерение,
  /// а не брак: пока он не измерил ленту, после печати он ищет промежуток там, где ему объявили,
  /// и промахивается — выдаёт лишнюю пустую этикетку либо мотает рулон до упора.
  Future<void> calibrate(LabelLanguage language) async =>
      printRaw(language.calibrate(await geometry()));

  /// Отправить готовые команды. Соединение поднимается само, если его ещё нет.
  Future<void> printRaw(List<int> bytes) async {
    await connect();
    await _transport.write(bytes);
  }

  //* --- разрешения --- *//

  /// Право на соединение с уже спаренным устройством.
  ///
  /// На Android 11 (ТСД пилота) такого runtime-права нет вовсе: `BLUETOOTH` выдаётся при
  /// установке, и запрашивать нечего. Проверка нужна для терминалов на Android 12+, где
  /// появился `BLUETOOTH_CONNECT`.
  Future<void> _requireConnectPermission() async {
    if (!Platform.isAndroid) return;
    await _require(Permission.bluetoothConnect, 'соединение с принтером');
  }

  /// Право на поиск новых устройств.
  ///
  /// Здесь версии Android расходятся принципиально: до 12 обнаружение считается определением
  /// местоположения и требует геолокации, с 12 — своего `BLUETOOTH_SCAN`. Спрашиваем оба;
  /// неприменимое на этой версии вернёт «выдано» и не побеспокоит человека.
  Future<void> _requireScanPermission() async {
    if (!Platform.isAndroid) return;
    await _require(Permission.bluetoothScan, 'поиск принтера');
    await _require(Permission.locationWhenInUse, 'поиск принтера');
  }

  /// Запрашивает разрешение и переводит отказ в доменную ошибку.
  ///
  /// Отказ намеренно не глушим: без права поиск молча возвращает пустой список, и человек
  /// решит, что принтер сломан, вместо того чтобы разрешить доступ.
  Future<void> _require(Permission permission, String what) async {
    final status = await permission.status;
    if (status.isGranted || status.isLimited) return;
    // Permanently denied сюда тоже попадает: повторный запрос вернёт тот же отказ, и человеку
    // нужно идти в настройки приложения — об этом и говорит сообщение.
    final asked = await permission.request();
    if (asked.isGranted || asked.isLimited) return;
    throw PrinterFailure(
      PrinterFailureKind.permission,
      'Нет разрешения на $what. Выдайте его в настройках приложения.',
    );
  }
}
