import 'package:craft_wms/core/database/app_database.dart';
import 'package:craft_wms/core/printer/label_geometry.dart';
import 'package:craft_wms/core/printer/label_language.dart';
import 'package:craft_wms/core/printer/printer_device.dart';
import 'package:craft_wms/core/printer/printer_service.dart';
import 'package:craft_wms/core/printer/printer_settings.dart';
import 'package:craft_wms/core/printer/printer_transport.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// Поведение сервиса печати (P4-05): выбор принтера, соединение, отправка команд.
///
/// Транспорт подменён: настоящий требует Bluetooth-железа, а проверять надо решения сервиса —
/// когда он подключается, когда не подключается повторно и что именно уходит в принтер.
class FakeTransport implements PrinterTransport {
  PrinterStatus _status = const PrinterStatus(
    supported: true,
    enabled: true,
    connected: false,
  );

  final List<String> bonds = [];
  final List<String> connects = [];
  final List<List<int>> writes = [];
  int disconnects = 0;

  /// Соединение рвётся при следующей попытке записи — имитация ухода принтера из зоны.
  bool failWrite = false;

  @override
  Future<PrinterStatus> status() async => _status;

  @override
  Future<List<PrinterDevice>> bondedDevices() async => const [
    PrinterDevice(address: '00:11:22:33:44:55', name: 'XP-P323B'),
  ];

  @override
  Stream<PrinterDevice> discover() =>
      Stream.value(const PrinterDevice(address: 'AA:BB', name: 'Найденный'));

  /// Спаривание отвергнуто принтером — как на живой проверке с XP-P323B.
  bool failBond = false;

  @override
  Future<void> bond(String address) async {
    if (failBond) {
      throw const PrinterFailure(
        PrinterFailureKind.pairing,
        'Принтер не принял спаривание',
      );
    }
    bonds.add(address);
  }

  @override
  Future<void> connect(String address) async {
    connects.add(address);
    _status = PrinterStatus(
      supported: true,
      enabled: true,
      connected: true,
      address: address,
    );
  }

  @override
  Future<void> write(List<int> bytes) async {
    if (failWrite) {
      throw const PrinterFailure(
        PrinterFailureKind.io,
        'Связь с принтером потеряна',
      );
    }
    writes.add(bytes);
  }

  @override
  Future<void> disconnect() async {
    disconnects++;
    _status = const PrinterStatus(
      supported: true,
      enabled: true,
      connected: false,
    );
  }
}

void main() {
  late AppDatabase db;
  late FakeTransport transport;
  late PrinterService service;

  const printer = PrinterDevice(address: '00:11:22:33:44:55', name: 'XP-P323B');

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    transport = FakeTransport();
    service = PrinterService(transport, PrinterSettings(db));
  });

  tearDown(() => db.close());

  test('без выбранного принтера печать отказывает внятно, а не падает', () async {
    // Кладовщик мог не дойти до выбора принтера: это рабочая ситуация, а не сбой.
    await expectLater(
      service.printTestLabel(const TsplLanguage()),
      throwsA(
        isA<PrinterFailure>().having(
          (e) => e.kind,
          'kind',
          PrinterFailureKind.io,
        ),
      ),
    );
    expect(transport.writes, isEmpty);
  });

  test('выбор принтера спаривает его, запоминает и поднимает соединение', () async {
    await service.select(printer);

    // Спаривание идёт ПЕРЕД подключением: неявное, которое запускает сам сокет, Android
    // ведёт без запроса PIN, и на живой проверке принтер его отверг (HCI 0x05).
    expect(transport.bonds, [printer.address]);
    expect(transport.connects, [printer.address]);
    expect((await service.selected())?.address, printer.address);
    expect((await service.selected())?.name, 'XP-P323B');
  });

  test('повторное подключение к тому же принтеру сокет не пересоздаёт', () async {
    // Установка RFCOMM-сокета заметно долгая, и переподключение на каждую этикетку
    // заставляло бы человека ждать у принтера.
    await service.select(printer);
    await service.connect();
    await service.connect();

    expect(transport.connects, hasLength(1));
  });

  test(
    'печать тестовой этикетки отправляет команды выбранного языка',
    () async {
      await service.select(printer);

      await service.printTestLabel(const ZplLanguage());

      expect(transport.writes, hasLength(1));
      expect(
        transport.writes.single,
        const ZplLanguage().testLabel(LabelGeometry.fallback),
      );
    },
  );

  test('печать поднимает соединение сама, если его ещё нет', () async {
    await service.select(printer);
    await service.disconnect();

    await service.printTestLabel(const TsplLanguage());

    expect(transport.connects, hasLength(2));
    expect(transport.writes, hasLength(1));
  });

  test('обрыв связи доходит до вызывающего, а не теряется', () async {
    await service.select(printer);
    transport.failWrite = true;

    await expectLater(
      service.printTestLabel(const TsplLanguage()),
      throwsA(
        isA<PrinterFailure>().having(
          (e) => e.kind,
          'kind',
          PrinterFailureKind.io,
        ),
      ),
    );
  });

  test('отказ спаривания не запоминает принтер и не доходит до сокета', () async {
    // Иначе терминал считал бы принтер выбранным, а печать молча падала бы при каждой попытке.
    transport.failBond = true;

    await expectLater(
      service.select(printer),
      throwsA(
        isA<PrinterFailure>().having(
          (e) => e.kind,
          'kind',
          PrinterFailureKind.pairing,
        ),
      ),
    );
    expect(transport.connects, isEmpty);
    expect(await service.selected(), isNull);
  });

  test('язык команд запоминается между запусками', () async {
    await service.selectLanguage(const ZplLanguage());

    expect((await service.language()).id, 'zpl');
  });

  test('по умолчанию язык — TSPL', () async {
    // Он заявлен основным; какой примет конкретный экземпляр, выясняется печатью.
    expect((await service.language()).id, 'tspl');
  });

  test('сохранённый язык, которого больше нет, не роняет сервис', () async {
    await PrinterSettings(db).saveLanguage('escpos');

    expect((await service.language()).id, 'tspl');
  });

  test('размер рулона запоминается и уходит в команды печати', () async {
    // Зашитый размер и был причиной лишних пустых этикеток: принтер догонял ленту до
    // промежутка, которого не было там, где ему объявили.
    await service.select(printer);
    const stock = LabelGeometry(widthMm: 58, heightMm: 30, gapMm: 3);

    await service.saveGeometry(stock);
    await service.printTestLabel(const TsplLanguage());

    expect(await service.geometry(), stock);
    expect(transport.writes.single, const TsplLanguage().testLabel(stock));
  });

  test('до настройки размер берётся умолчанием, а не пустым', () async {
    expect(await service.geometry(), LabelGeometry.fallback);
  });

  test('калибровка уходит в принтер отдельной командой', () async {
    await service.select(printer);

    await service.calibrate(const TsplLanguage());

    expect(
      transport.writes.single,
      const TsplLanguage().calibrate(LabelGeometry.fallback),
    );
  });

  test('«забыть принтер» рвёт соединение и чистит выбор', () async {
    await service.select(printer);

    await service.forget();

    expect(transport.disconnects, 1);
    expect(await service.selected(), isNull);
  });
}
