import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:craft_wms/core/database/app_database.dart';
import 'package:craft_wms/core/load_unit/load_unit_id_generator.dart';
import 'package:craft_wms/core/outbox/operations_api.dart';
import 'package:craft_wms/core/outbox/outbox_effects.dart';
import 'package:craft_wms/core/outbox/outbox_repository.dart';
import 'package:craft_wms/core/outbox/outbox_sender.dart';
import 'package:craft_wms/core/printer/printer_service.dart';
import 'package:craft_wms/core/sync/sync_engine.dart';
import 'package:craft_wms/features/receipt/data/receipt_draft_store.dart';
import 'package:craft_wms/features/receipt/data/receipt_repository.dart';
import 'package:craft_wms/features/receipt/presentation/bloc/receipt_cubit.dart';
import 'package:craft_wms/features/receipt/presentation/bloc/receipt_models.dart';
import 'package:craft_wms/features/stock/data/catalog_api.dart';
import 'package:craft_wms/features/stock/data/catalog_cache.dart';
import 'package:craft_wms/features/stock/data/catalog_models.dart';
import 'package:craft_wms/features/stock/data/catalog_repository.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:uuid/data.dart';
import 'package:uuid/uuid.dart';

import '../../support/fake_operations_server.dart';
import '../../support/contents_stubs.dart';

class _MockConnectivity extends Mock implements Connectivity {}

class _MockPrinter extends Mock implements PrinterService {}

/// Идентификаторы по порядку выдачи: терминал выдаёт их сам, а эталону нужны постоянные.
class _SequenceUuid extends Fake implements Uuid {
  _SequenceUuid(this._ids);

  final List<String> _ids;
  var _next = 0;

  @override
  String v4({Map<String, dynamic>? options, V4Options? config}) =>
      _ids[_next++];
}

/// Эталон формата приёмки — половина контракта на стороне клиента (P4-11D).
///
/// Что: приёмка собирается настоящим cubit и уходит настоящим путём — очередь, движок
/// синхронизации, батч `POST /operations`. Тело батча сверяется с файлом-эталоном.
/// Зачем: тело `receipt_submit` собирают Dart (cubit) и разбирает Go (сервис операций). Порознь
///        их ничто не связывает: переименуй поле одна сторона — обе останутся зелёными, а
///        приёмки молча начнут отклоняться. Вторая половина — `receiving_scenario_http_test.go`
///        на бэкенде: тот же файл уходит настоящему роутеру.
/// Как: тот же приём, что у эталона привязок ШК (P2-08, `wire_contract_test.dart`).
const _fixturePath = '../backend/internal/handler/testdata/receipt_submit.json';

void main() {
  test('клиент шлёт приёмку ровно в формате эталона', () async {
    final fixtureFile = File(_fixturePath);
    expect(
      fixtureFile.existsSync(),
      isTrue,
      reason: 'эталон не найден: $_fixturePath',
    );
    final expected =
        jsonDecode(fixtureFile.readAsStringSync()) as Map<String, dynamic>;
    final expectedOp =
        (expected['operations'] as List<dynamic>).single
            as Map<String, dynamic>;
    final p = expectedOp['payload'] as Map<String, dynamic>;
    final lines = (p['lines'] as List<dynamic>).cast<Map<String, dynamic>>();
    final boxLine = lines.firstWhere((l) => l.containsKey('load_unit_id'));
    final looseLine = lines.firstWhere((l) => !l.containsKey('load_unit_id'));

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final cache = CatalogCache(db);
    final outbox = OutboxRepository(db, const Uuid());
    final effects = OutboxEffects(cache, FakeContentsSnapshotSync());
    final server = FakeOperationsServer();
    final dio = Dio(BaseOptions(baseUrl: 'https://api.test/api/v1/'))
      ..httpClientAdapter = server;
    final engine = SyncEngine(
      outbox,
      OutboxSender(OperationsApi(dio)),
      effects,
      Talker(),
      _MockConnectivity(),
    );
    final catalog = CatalogRepository(
      CatalogApi(dio),
      cache,
      outbox,
      effects,
      engine,
    );

    // Справочники терминала — с идентификаторами эталона: подстановка значений превратила бы
    // проверку формата в проверку подстановки.
    final defaultCell = Cell(
      id: 'not-in-payload', // ячейку по умолчанию терминал не шлёт — её подставляет сервер
      warehouseId: p['warehouse_id'] as String,
      address: 'С-Н-П',
      isDefault: true,
    );
    final cell1 = Cell(
      id: boxLine['cell_id'] as String,
      warehouseId: p['warehouse_id'] as String,
      address: 'M1-1-1-1',
    );
    await cache.putCells([defaultCell, cell1]);
    final supplier = Supplier(
      id: p['supplier_id'] as String,
      name: 'Поставщик',
    );
    final good = Good(
      id: boxLine['good_id'] as String,
      name: 'Кальмар',
      uom: 'шт',
    );

    final cubit = ReceiptCubit(
      catalog,
      ReceiptRepository(outbox, engine),
      ReceiptDraftStore(db),
      LoadUnitIdGenerator(
        _SequenceUuid([
          p['receipt_id'] as String,
          (p['load_units'] as List<dynamic>).single['id'] as String,
        ]),
      ),
      _MockPrinter(),
    );
    addTearDown(cubit.close);

    // Тот же путь, что у кладовщика: поставщик → короб в M1-1-1-1 → строка в коробе →
    // штучная строка в ячейку по умолчанию → «Завершить приёмку».
    await cubit.start(supplier);
    cubit.setTargetCell(cell1);
    final boxId = cubit.newBox();
    await cubit.addLine(
      good: good,
      date: (boxLine['production_date'] as String).replaceAll('-', '.'),
      qty: (boxLine['qty'] as num).toDouble(),
      boxId: boxId,
    );
    cubit.setTargetCell(defaultCell);
    await cubit.addLine(
      good: good,
      date: (looseLine['production_date'] as String).replaceAll('-', '.'),
      qty: (looseLine['qty'] as num).toDouble(),
    );
    await cubit.submit();
    expect(cubit.state.outcome, ReceiptOutcome.posted);

    final sentOp =
        (server.lastBody!['operations'] as List<dynamic>).single
            as Map<String, dynamic>;
    // operation_id выдаёт очередь, и в эталоне он зафиксирован: важно наличие поля под этим
    // именем, а не значение. Переименуй поле — в карте появится лишний ключ, сверка упадёт.
    final normalized = {...sentOp, 'operation_id': expectedOp['operation_id']};
    expect(
      normalized,
      equals(expectedOp),
      reason:
          'формат приёмки разошёлся с эталоном $_fixturePath.\n'
          'Клиент шлёт: ${jsonEncode(sentOp)}\n'
          'Эталон:      ${jsonEncode(expectedOp)}\n'
          'Меняли формат — обновите файл, его же читает тест бэкенда.',
    );
  });
}
