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
import 'package:craft_wms/features/cz/domain/cz_intake.dart';
import 'package:craft_wms/features/receipt/data/receipt_draft_store.dart';
import 'package:craft_wms/features/receipt/data/receipt_repository.dart';
import 'package:craft_wms/features/receipt/presentation/bloc/receipt_cubit.dart';
import 'package:craft_wms/features/receipt/presentation/bloc/receipt_models.dart';
import 'package:craft_wms/features/stock/data/catalog_api.dart';
import 'package:craft_wms/features/stock/data/catalog_cache.dart';
import 'package:craft_wms/features/stock/domain/catalog_models.dart';
import 'package:craft_wms/features/stock/data/catalog_repository_impl.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:uuid/data.dart';
import 'package:uuid/uuid.dart';

import '../../support/contents_stubs.dart';
import '../../support/fake_operations_server.dart';

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

/// Эталон приёмки с марками ЧЗ (CZ-05) - клиентская половина контракта.
///
/// Тот же приём, что у эталона приёмки без марок (`receipt_wire_contract_test.dart`): приёмка
/// собирается настоящим cubit и уходит настоящим путём, тело сверяется с файлом, который
/// бэкенд скармливает роутеру в `receiving_cz_http_test.go`.
const _fixturePath =
    '../backend/internal/handler/testdata/receipt_submit_cz.json';

void main() {
  test('клиент шлёт приёмку с марками ровно в формате эталона', () async {
    final expected =
        jsonDecode(File(_fixturePath).readAsStringSync())
            as Map<String, dynamic>;
    final expectedOp =
        (expected['operations'] as List<dynamic>).single
            as Map<String, dynamic>;
    final p = expectedOp['payload'] as Map<String, dynamic>;
    final lu =
        (p['load_units'] as List<dynamic>).single as Map<String, dynamic>;
    final czGroup =
        (p['cz_groups'] as List<dynamic>).single as Map<String, dynamic>;
    final lines = (p['lines'] as List<dynamic>).cast<Map<String, dynamic>>();
    final boxLine = lines.firstWhere((l) => l.containsKey('load_unit_id'));
    final looseLine = lines.firstWhere((l) => !l.containsKey('load_unit_id'));

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final cache = CatalogCache(db);
    final outbox = OutboxRepository(db, const Uuid());
    final effects = OutboxEffects(
      cache,
      FakeContentsSnapshotSync(),
      FakeTasksSnapshotSync(),
    );
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
    final catalog = CatalogRepositoryImpl(
      CatalogApi(dio),
      cache,
      outbox,
      effects,
      engine,
    );

    final defaultCell = Cell(
      id: 'not-in-payload',
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
    final good = Good(
      id: boxLine['good_id'] as String,
      name: 'Пиво светлое',
      uom: 'шт',
      czMarked: true,
    );

    final cubit = ReceiptCubit(
      catalog,
      ReceiptRepository(outbox, engine),
      ReceiptDraftStore(db),
      LoadUnitIdGenerator(
        _SequenceUuid([p['receipt_id'] as String, lu['id'] as String]),
      ),
      _MockPrinter(),
    );
    addTearDown(cubit.close);

    // Марки строки эталона - как их прочитал скан: упаковка и расхождение («» - нет).
    List<CzMarkDraft> marksOf(Map<String, dynamic> line) => [
      for (final m
          in (line['marks'] as List<dynamic>).cast<Map<String, dynamic>>())
        CzMarkDraft(
          cis: m['cis'] as String,
          aggregateCode: (m['aggregate_code'] as String).isEmpty
              ? null
              : m['aggregate_code'] as String,
          discrepancy: (m['discrepancy'] as String).isEmpty
              ? null
              : m['discrepancy'] as String,
        ),
    ];
    String date(Map<String, dynamic> line) =>
        (line['production_date'] as String).replaceAll('-', '.');

    // Путь кладовщика: накладная → ячейка M1-1-1-1 → скан короба ЧЗ → ячейка приёмки →
    // две марки россыпью (одна чужая) → «Завершить приёмку».
    await cubit.start(
      Supplier(id: p['supplier_id'] as String, name: 'Поставщик'),
      ReceiptDoc(
        number: p['doc_number'] as String,
        date: (p['doc_date'] as String).replaceAll('-', '.'),
      ),
    );
    cubit.setTargetCell(cell1);
    final added = cubit.addCzBox(
      code: lu['cz_code'] as String,
      lines: [
        CzIntakeLine(good: good, date: date(boxLine), marks: marksOf(boxLine)),
      ],
      groups: [
        CzGroupDraft(
          code: czGroup['code'] as String,
          parentCode: czGroup['parent_code'] as String,
        ),
      ],
    );
    expect(added.result, CzIntakeAdd.added);
    cubit.setTargetCell(defaultCell);
    for (final m in marksOf(looseLine)) {
      cubit.addCzMarks(
        lines: [
          CzIntakeLine(good: good, date: date(looseLine), marks: [m]),
        ],
      );
    }
    await cubit.submit();
    expect(cubit.state.outcome, ReceiptOutcome.posted);

    final sentOp =
        (server.lastBody!['operations'] as List<dynamic>).single
            as Map<String, dynamic>;
    final normalized = {...sentOp, 'operation_id': expectedOp['operation_id']};
    expect(
      normalized,
      equals(expectedOp),
      reason:
          'формат приёмки с марками разошёлся с эталоном $_fixturePath.\n'
          'Клиент шлёт: ${jsonEncode(sentOp)}\n'
          'Эталон:      ${jsonEncode(expectedOp)}\n'
          'Меняли формат - обновите файл, его же читает тест бэкенда.',
    );
  });
}
