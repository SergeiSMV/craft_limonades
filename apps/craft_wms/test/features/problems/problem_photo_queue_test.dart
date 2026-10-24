import 'dart:convert';
import 'dart:typed_data';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:craft_wms/core/database/app_database.dart';
import 'package:craft_wms/core/outbox/operations_api.dart';
import 'package:craft_wms/core/outbox/outbox_effects.dart';
import 'package:craft_wms/core/outbox/outbox_repository.dart';
import 'package:craft_wms/core/outbox/outbox_sender.dart';
import 'package:craft_wms/core/sync/sync_engine.dart';
import 'package:craft_wms/features/problems/data/problem_photo_repository_impl.dart';
import 'package:craft_wms/features/problems/domain/problem_photos.dart';
import 'package:craft_wms/features/stock/data/catalog_cache.dart';
import 'package:dio/dio.dart';
// Только Migrator: полный экспорт drift переопределяет матчеры теста.
import 'package:drift/drift.dart' show Migrator;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../support/contents_stubs.dart';

class _MockConnectivity extends Mock implements Connectivity {}

/// Сервер фото: какие проблемы он знает, что принял, связь (ADHOC-45).
class _PhotoServer implements HttpClientAdapter {
  bool offline = false;

  /// Проблемы, которые уже на сервере; снимок к другой — 404.
  final Set<String> problems = {};

  /// Проблемы, у которых решение уже принято, — 409.
  final Set<String> resolved = {};

  /// Принятые снимки: путь → размер.
  final Map<String, int> stored = {};

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (offline) {
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'нет связи',
      );
    }
    final parts = options.path.split('/'); // problems/{id}/photos/{photoId}
    final problem = parts[1];
    if (!problems.contains(problem)) return _error(404, 'проблема не найдена');
    if (resolved.contains(problem)) return _error(409, 'решение принято');
    final bytes = <int>[];
    await for (final chunk
        in requestStream ?? const Stream<Uint8List>.empty()) {
      bytes.addAll(chunk);
    }
    stored[options.path] = bytes.length;
    return ResponseBody.fromString('', 204);
  }

  ResponseBody _error(int code, String message) => ResponseBody.fromString(
    jsonEncode({'error': message}),
    code,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );

  @override
  void close({bool force = false}) {}
}

/// Очередь фото проблем (ADHOC-45): снимки ждут, пока проблема не дошла, уходят по порядку,
/// отказ по существу убирает снимок, без связи — ждут.
void main() {
  late AppDatabase db;
  late _PhotoServer server;
  late ProblemPhotoRepositoryImpl repo;

  ProblemPhotoShot shot(String id) => ProblemPhotoShot(
    id: id,
    content: Uint8List.fromList([0xFF, 0xD8, 0xFF, 1]),
  );

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    server = _PhotoServer();
    final dio = Dio(BaseOptions(baseUrl: 'https://api.test/api/v1/'))
      ..httpClientAdapter = server;
    final outbox = OutboxRepository(db, const Uuid());
    final engine = SyncEngine(
      outbox,
      OutboxSender(OperationsApi(dio)),
      OutboxEffects(
        CatalogCache(db),
        FakeContentsSnapshotSync(),
        FakeTasksSnapshotSync(),
      ),
      Talker(),
      _MockConnectivity(),
    );
    repo = ProblemPhotoRepositoryImpl(db, dio, engine, Talker());
  });

  tearDown(() => db.close());

  Future<int> pending() => repo.watchPendingCount().first;

  test('проблема уже на сервере — снимки уходят и покидают очередь', () async {
    server.problems.add('p1');
    await repo.enqueue('p1', [shot('a'), shot('b')]);
    expect(server.stored.keys, [
      'problems/p1/photos/a',
      'problems/p1/photos/b',
    ]);
    expect(await pending(), 0);
  });

  test('проблемы ещё нет — снимки ждут и уходят, когда она дошла', () async {
    await repo.enqueue('p1', [shot('a')]);
    expect(await pending(), 1);
    expect((await repo.pendingOf('p1')).single.id, 'a');

    server.problems.add('p1');
    await repo.upload();
    expect(await pending(), 0);
    expect(server.stored, contains('problems/p1/photos/a'));
  });

  test('без связи снимки ждут; отказ по существу снимок убирает', () async {
    server.problems.addAll(['p1', 'p2']);
    server.offline = true;
    await repo.enqueue('p1', [shot('a')]);
    expect(await pending(), 1);

    server.offline = false;
    server.resolved.add('p2');
    await repo.enqueue('p2', [shot('b')]);
    expect(await pending(), 0, reason: 'a ушёл, b отклонён и убран');
    expect(server.stored.keys, ['problems/p1/photos/a']);
  });

  test('миграция 10 → 11 заводит очередь фото', () async {
    await db.customStatement('DROP TABLE problem_photo_uploads');
    await db.migration.onUpgrade(Migrator(db), 10, 11);
    await repo.enqueue('p1', [shot('a')]);
    expect(await pending(), 1);
  });
}
