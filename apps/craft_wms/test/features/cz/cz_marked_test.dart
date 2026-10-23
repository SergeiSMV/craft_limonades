import 'package:craft_wms/core/constants/api_constants.dart';
import 'package:craft_wms/core/database/app_database.dart';
import 'package:craft_wms/core/error/failure.dart';
import 'package:craft_wms/core/outbox/outbox_effects.dart';
import 'package:craft_wms/core/outbox/outbox_operation.dart';
import 'package:craft_wms/features/cz/data/cz_good_repository_impl.dart';
import 'package:craft_wms/features/cz/presentation/bloc/cz_marked_cubit.dart';
import 'package:craft_wms/features/stock/data/catalog_cache.dart';
import 'package:craft_wms/features/stock/data/catalog_models.dart';
import 'package:dio/dio.dart';
// Только Migrator: полный экспорт drift переопределяет матчеры теста.
import 'package:drift/drift.dart' show Migrator;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../support/contents_stubs.dart';

class _MockDio extends Mock implements Dio {}

/// Признак «маркируемый» на ТСД (CZ-05): кэш товаров, правка admin, привязка ШК из марки.
void main() {
  late AppDatabase db;
  late CatalogCache cache;
  late _MockDio dio;

  const good = Good(id: 'g1', name: 'Пиво светлое', uom: 'шт');

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    cache = CatalogCache(db);
    dio = _MockDio();
    await cache.putGoods([good]);
  });

  tearDown(() => db.close());

  Future<bool?> marked() async => (await cache.goodById(good.id))?.czMarked;

  void patchAnswers(Future<Response<Map<String, dynamic>>> Function() answer) =>
      when(
        () => dio.patch<Map<String, dynamic>>(
          ApiConst.goodCzMarked(good.id),
          data: any(named: 'data'),
        ),
      ).thenAnswer((_) => answer());

  test('признак приходит со справочником и ложится в кэш', () async {
    await cache.putGoods([good.copyWith(czMarked: true)]);
    expect(await marked(), isTrue);
    expect(
      Good.fromJson({'id': 'g', 'name': 'n', 'uom': 'шт'}).czMarked,
      isFalse,
      reason: 'старый сервер поле не шлёт',
    );
  });

  test('правка admin: сервер принял — кэш и экран с новым признаком', () async {
    patchAnswers(
      () async => Response(
        requestOptions: RequestOptions(path: ''),
        statusCode: 200,
        data: {'id': good.id, 'cz_marked': true},
      ),
    );
    final cubit = CzMarkedCubit(CzGoodRepositoryImpl(dio, cache))
      ..start(goodId: good.id, marked: false);

    await cubit.set(true);

    expect(cubit.state.marked, isTrue);
    expect(cubit.state.failure, isNull);
    expect(await marked(), isTrue);
    verify(
      () => dio.patch<Map<String, dynamic>>(
        ApiConst.goodCzMarked(good.id),
        data: {'cz_marked': true},
      ),
    ).called(1);
    await cubit.close();
  });

  test('без связи признак прежний — и на экране, и в кэше', () async {
    patchAnswers(
      () async => throw DioException(
        requestOptions: RequestOptions(path: ''),
        type: DioExceptionType.connectionError,
      ),
    );
    final cubit = CzMarkedCubit(CzGoodRepositoryImpl(dio, cache))
      ..start(goodId: good.id, marked: false);

    await cubit.set(true);

    expect(cubit.state.marked, isFalse);
    expect(cubit.state.failure, isA<NetworkFailure>());
    expect(await marked(), isFalse);
    await cubit.close();
  });

  test('привязка ШК из марки помечает товар сразу, обычная — нет', () async {
    final effects = OutboxEffects(
      cache,
      FakeContentsSnapshotSync(),
      FakeTasksSnapshotSync(),
    );
    await effects.applyOptimistic(
      kind: OutboxKind.bindBarcode,
      payload: {'good_id': good.id, 'barcode': '4612728200172'},
    );
    expect(await marked(), isFalse);

    await effects.applyOptimistic(
      kind: OutboxKind.bindBarcode,
      payload: {
        'good_id': good.id,
        'barcode': '4612728200173',
        'from_cz_mark': true,
      },
    );
    expect(await marked(), isTrue);
  });

  test('миграция 9 → 10: признак «нет», справочник товаров перечитать', () async {
    await db.customStatement('DROP TABLE cached_goods');
    await db.customStatement(
      'CREATE TABLE cached_goods (id TEXT NOT NULL, code TEXT, name TEXT NOT NULL, '
      'full_name TEXT, uom TEXT NOT NULL, group_id TEXT, group_name TEXT, '
      'supplier_id TEXT, supplier_name TEXT, is_active INTEGER NOT NULL DEFAULT 1, '
      'search_text TEXT NOT NULL, PRIMARY KEY (id))',
    );
    await db.customStatement(
      "INSERT INTO cached_goods (id, name, uom, search_text) VALUES ('g1', 'Пиво', 'шт', 'пиво')",
    );
    await db.customStatement(
      "INSERT OR REPLACE INTO catalog_sync_marks VALUES ('goods', 0)",
    );

    await db.migration.onUpgrade(Migrator(db), 9, 10);

    expect(await marked(), isFalse);
    expect(await cache.syncedAt(CatalogName.goods), isNull);
  });
}
