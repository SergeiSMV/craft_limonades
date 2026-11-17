import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:craft_wms/core/database/app_database.dart';
import 'package:craft_wms/core/outbox/operations_api.dart';
import 'package:craft_wms/core/outbox/outbox_effects.dart';
import 'package:craft_wms/core/outbox/outbox_repository.dart';
import 'package:craft_wms/core/outbox/outbox_sender.dart';
import 'package:craft_wms/core/sync/sync_engine.dart';
import 'package:craft_wms/features/stock/data/catalog_api.dart';
import 'package:craft_wms/features/stock/data/catalog_cache.dart';
import 'package:craft_wms/features/stock/data/catalog_models.dart';
import 'package:craft_wms/features/stock/data/catalog_repository.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:uuid/uuid.dart';

import '../support/fake_operations_server.dart';
import '../support/contents_stubs.dart';

class _MockConnectivity extends Mock implements Connectivity {}

/// Эталон формата батча операций - половина контракта на стороне клиента (P2-08).
///
/// Что: проверяет, что клиент шлёт ровно то тело, которое лежит в общем файле-эталоне.
/// Зачем: формат утверждался дважды независимо - здесь руками написанным JSON, на бэкенде
///        руками написанными структурами. Ничто их не связывало: разойдись имя поля, обе
///        стороны остались бы зелёными, а терминал молча перестал бы синхронизироваться.
/// Как: один файл, на который смотрят оба теста. Второй половиной контракта служит
///      `operations_http_test.go`: он скармливает тот же файл настоящему роутеру.
///
/// Файл лежит в дереве бэкенда, потому что там же живёт разбирающий его код; путь относителен
/// каталога, из которого запускаются тесты Flutter-приложения.
const _fixturePath = '../backend/internal/handler/testdata/outbox_batch.json';

void main() {
  test('клиент шлёт батч ровно в формате эталона', () async {
    final fixtureFile = File(_fixturePath);
    expect(
      fixtureFile.existsSync(),
      isTrue,
      reason: 'эталон формата не найден: $_fixturePath',
    );
    final expected =
        jsonDecode(fixtureFile.readAsStringSync()) as Map<String, dynamic>;
    final expectedOps = (expected['operations'] as List<dynamic>)
        .cast<Map<String, dynamic>>();

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
    final repo = CatalogRepository(
      CatalogApi(dio),
      cache,
      outbox,
      effects,
      engine,
    );

    final goodId = expectedOps.first['payload']['good_id'] as String;
    final barcode = expectedOps.first['payload']['barcode'] as String;
    await cache.putGoods([Good(id: goodId, name: 'Арахис жареный', uom: 'шт')]);
    await cache.putBarcodes([]);

    // Копим ровно те операции, что лежат в эталоне, и отправляем одним батчем.
    server.offline = true;
    await repo.bindBarcode(goodId: goodId, barcode: barcode);
    await repo.unbindBarcode(goodId: goodId, barcode: barcode);
    server.offline = false;
    await engine.drain();

    final sent = server.lastBody;
    expect(sent, isNotNull, reason: 'батч до сервера не дошёл');
    final sentOps = (sent!['operations'] as List<dynamic>)
        .cast<Map<String, dynamic>>();

    expect(
      sentOps,
      hasLength(expectedOps.length),
      reason: 'число операций в батче разошлось с эталоном',
    );
    for (var i = 0; i < sentOps.length; i++) {
      // operation_id генерится на устройстве и в эталоне зафиксирован: сравнивать его значение
      // бессмысленно, а вот НАЛИЧИЕ поля под этим именем - весь смысл контракта. Подменяем
      // значение эталонным: если поле переименуют, в карте появится лишний ключ и сверка упадёт.
      final normalized = {
        ...sentOps[i],
        'operation_id': expectedOps[i]['operation_id'],
      };
      expect(
        normalized,
        equals(expectedOps[i]),
        reason:
            'формат операции $i разошёлся с эталоном $_fixturePath.\n'
            'Клиент шлёт: ${jsonEncode(sentOps[i])}\n'
            'Эталон:      ${jsonEncode(expectedOps[i])}\n'
            'Меняли формат - обновите файл, его же читает тест бэкенда.',
      );
    }
  });
}
