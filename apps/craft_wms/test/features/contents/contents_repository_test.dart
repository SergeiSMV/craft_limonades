import 'dart:convert';
import 'dart:io';

import 'package:craft_wms/core/database/app_database.dart';
import 'package:craft_wms/core/error/failure.dart';
import 'package:craft_wms/core/outbox/outbox_operation.dart';
import 'package:craft_wms/core/outbox/outbox_repository.dart';
import 'package:craft_wms/core/warehouse/internal_warehouses.dart';
import 'package:craft_wms/features/contents/data/contents_api.dart';
import 'package:craft_wms/features/contents/data/contents_cache.dart';
import 'package:craft_wms/features/contents/data/contents_dto.dart';
import 'package:craft_wms/features/contents/data/contents_repository_impl.dart';
import 'package:craft_wms/features/contents/domain/contents_entities.dart';
import 'package:craft_wms/features/stock/data/catalog_cache.dart';
import 'package:craft_wms/features/stock/domain/catalog_models.dart';
import 'package:drift/drift.dart' show Migrator, Value;
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:either_dart/either.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:uuid/uuid.dart';

class _MockApi extends Mock implements ContentsApi {}

/// Эталон ответа снимка - общий с сервером (`contents_http_test.go`): сервер обязан отдавать
/// ровно его, терминал - разбирать.
const _fixturePath =
    '../backend/internal/handler/testdata/contents_snapshot.json';

/// Содержимое ячейки и короба на терминале (P5-05): сервер → снимок → своя очередь поверх.
void main() {
  late AppDatabase db;
  late _MockApi api;
  late ContentsCache cache;
  late CatalogCache catalog;
  late OutboxRepository outbox;
  late ContentsRepositoryImpl repo;
  late ContentsSnapshot fixture;

  // Идентификаторы эталона.
  const box = '5a0c1d2e-3f40-4b51-8c62-7d8e9fa0b1c2';
  const boxCell = 'c1e2d3f4-0a1b-4c2d-9e3f-405162738495';
  const looseCell = 'd0e1f2a3-b4c5-4d6e-8f70-8192a3b4c5d6';
  const good = 'a7b8c9d0-e1f2-4a3b-8c4d-5e6f70819203';
  const wh = 'f0000000-0000-4000-8000-000000000001';
  // Склад эталона - «Основной»; «Брак» - для пометок (P6-07-2).
  const mainIwh = 'e0000000-0000-4000-8000-000000000001';
  const defectIwh = 'e0000000-0000-4000-8000-0000000000de';

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    api = _MockApi();
    cache = ContentsCache(db);
    catalog = CatalogCache(db);
    outbox = OutboxRepository(db, const Uuid());
    await db.batch(
      (b) => b.insertAll(db.cachedInternalWarehouses, [
        CachedInternalWarehousesCompanion.insert(
          id: mainIwh,
          code: 'MAIN',
          name: 'Основной',
          isDefault: const Value(true),
        ),
        CachedInternalWarehousesCompanion.insert(
          id: defectIwh,
          code: 'DEFECT',
          name: 'Брак',
        ),
      ]),
    );
    repo = ContentsRepositoryImpl(
      api,
      cache,
      catalog,
      outbox,
      InternalWarehouses(Dio(), db),
    );
    fixture = ContentsSnapshot.fromJson(
      jsonDecode(File(_fixturePath).readAsStringSync()) as Map<String, dynamic>,
    );
    await catalog.putCells(const [
      Cell(id: boxCell, warehouseId: wh, address: 'A-1-1'),
      Cell(id: looseCell, warehouseId: wh, address: 'С-Н-П', isDefault: true),
    ]);
    await catalog.putGoods(const [
      Good(id: good, code: '16121', name: 'Кальмар', uom: 'шт'),
    ]);
    when(
      () => api.card(any()),
    ).thenAnswer((_) async => const Left(Failure.network()));
    when(
      () => api.cell(any()),
    ).thenAnswer((_) async => const Left(Failure.network()));
  });

  tearDown(() => db.close());

  test('эталон снимка разбирается: короб с содержимым и россыпь', () {
    expect(fixture.asOf, DateTime.utc(2026, 10, 8, 9));
    expect(fixture.loadUnits.single.id, box);
    expect(fixture.loadUnits.single.cellId, boxCell);
    expect(fixture.loadUnits.single.lines.single.qty, 12);
    expect(fixture.loadUnits.single.lines.single.productionDate, '01-09-2026');
    expect(fixture.loose.single.cellId, looseCell);
    expect(fixture.loose.single.line.qty, 3);
  });

  test('без связи - снимок с моментом и наименованиями из справочника', () async {
    await cache.replace(fixture);

    final res = await repo.loadUnit(box);
    final viewed = res.right;
    expect(viewed.freshness, isA<FromSnapshot>());
    // drift отдаёт время по местному поясу - сравниваем момент, а не представление.
    expect(
      (viewed.freshness as FromSnapshot).asOf!.isAtSameMomentAs(fixture.asOf),
      isTrue,
    );
    expect(viewed.value!.cellAddress, 'A-1-1');
    expect(viewed.value!.lines.single.goodName, 'Кальмар');

    final cell = (await repo.cell(
      const CellRef(id: looseCell, address: 'С-Н-П'),
    )).right.value!;
    expect(cell.loadUnits, isEmpty);
    expect(cell.loose.single.qty, 3);
    expect(cell.loose.single.goodName, 'Кальмар');
  });

  test(
    'без связи и без снимка - показать нечего, кроме своих операций',
    () async {
      expect((await repo.loadUnit(box)).left, isA<NetworkFailure>());

      // Своя неотправленная приёмка короба - его уже есть что показать.
      await outbox.enqueue(
        kind: OutboxKind.receiptSubmit,
        payload: {
          'warehouse_id': wh,
          'load_units': [
            {'id': box, 'kind': 'box'},
          ],
          'lines': [
            {
              'good_id': good,
              'production_date': '01-09-2026',
              'qty': 5,
              'load_unit_id': box,
            },
          ],
        },
      );
      final viewed = (await repo.loadUnit(box)).right;
      expect((viewed.freshness as FromSnapshot).asOf, isNull);
      expect(viewed.value!.cellAddress, 'С-Н-П');
      expect(viewed.value!.pending, isTrue);
    },
  );

  test('со связью - ответ сервера, снимок не читается', () async {
    await cache.replace(fixture);
    when(() => api.card(box)).thenAnswer(
      (_) async => const Right(
        LoadUnitView(
          id: box,
          cellId: looseCell,
          cellAddress: 'С-Н-П',
          live: true,
        ),
      ),
    );

    final viewed = (await repo.loadUnit(box)).right;
    expect(viewed.freshness, isA<FreshFromServer>());
    expect(
      viewed.value!.cellAddress,
      'С-Н-П',
    ); // сервер, а не снимок (там A-1-1)
  });

  test('сервер не знает короба - «не найден», а не снимок', () async {
    await cache.replace(fixture);
    when(
      () => api.card(box),
    ).thenAnswer((_) async => const Left(Failure.server(404)));

    final viewed = (await repo.loadUnit(box)).right;
    expect(viewed.value, isNull);
    expect(viewed.freshness, isA<FreshFromServer>());
  });

  test('новый снимок заменяет прежний целиком', () async {
    await cache.replace(fixture);
    await cache.replace(
      ContentsSnapshot(
        asOf: DateTime.utc(2026, 10, 9),
        loadUnits: const [],
        loose: const [],
      ),
    );

    expect(await cache.loadUnits([box]), isEmpty);
    expect(await cache.looseInCell(looseCell), isEmpty);
    expect(
      (await cache.asOf())!.isAtSameMomentAs(DateTime.utc(2026, 10, 9)),
      isTrue,
    );
  });

  test('ячейка ищется по точному адресу, без учёта регистра', () async {
    await catalog.putCells(const [
      Cell(id: 'c1', warehouseId: wh, address: 'A-1-1'),
      Cell(id: 'c10', warehouseId: wh, address: 'A-1-10'),
    ]);

    expect((await repo.findCell('a-1-1'))?.id, 'c1');
    expect(await repo.findCell('A-1'), isNull);
  });

  test('миграция 6 → 7 заводит таблицы снимка', () async {
    for (final t in [
      'cached_load_units',
      'cached_load_unit_lines',
      'cached_loose_stock',
    ]) {
      await db.customStatement('DROP TABLE $t');
    }

    await db.migration.onUpgrade(Migrator(db), 6, 7);

    await cache.replace(fixture);
    expect((await cache.loadUnits([box])).keys, [box]);
  });

  test(
    'миграция 7 → 8: склад у коробов снимка, справочник складов, снимок перечитать',
    () async {
      await db.customStatement('DROP TABLE cached_internal_warehouses');
      await db.customStatement('DROP TABLE cached_load_units');
      // Таблица версии 7 плюс колонки, которые добавит шаг 12 (CZ-06): тест гоняет один
      // шаг 7 → 8, а снимок пишется по текущей схеме.
      await db.customStatement(
        'CREATE TABLE cached_load_units (id TEXT NOT NULL, kind TEXT NOT NULL, '
        'cell_id TEXT NOT NULL, created_at INTEGER NOT NULL, cz_code TEXT, '
        'cz_opened INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (id))',
      );
      await db
          .into(db.catalogSyncMarks)
          .insert(
            CatalogSyncMarksCompanion.insert(
              catalog: ContentsCache.markName,
              syncedAt: DateTime.utc(2026, 10, 8),
            ),
          );

      await db.migration.onUpgrade(Migrator(db), 7, 8);

      expect(
        await cache.asOf(),
        isNull,
        reason: 'склад коробов неизвестен - снимок перечитать',
      );
      await cache.replace(fixture);
      expect((await cache.loadUnits([box]))[box]?.internalWarehouseId, mainIwh);
      expect(await db.select(db.cachedInternalWarehouses).get(), isEmpty);
    },
  );

  group('пометка брака своей очередью (P6-07-2)', () {
    setUp(() => cache.replace(fixture));

    Future<void> pendingProblem(Map<String, dynamic> body) => outbox.enqueue(
      kind: OutboxKind.problemSubmit,
      payload: {
        'problem_id': const Uuid().v4(),
        'warehouse_id': wh,
        'to_internal_warehouse_id': defectIwh,
        'reason': 'breakage',
        ...body,
      },
    );

    test('короб целиком - «Брак» со всем составом, склад подписан', () async {
      await pendingProblem({'load_unit_id': box});

      final lu = (await repo.loadUnit(box)).right.value!;
      expect(lu.internalWarehouseId, defectIwh);
      expect(lu.internalWarehouseName, 'Брак');
      expect(lu.lines.single.internalWarehouseId, defectIwh);
      expect(lu.pending, isTrue);
    });

    test(
      'часть короба - вынута в россыпь брака той же ячейки, короб основной',
      () async {
        await pendingProblem({
          'good_id': good,
          'production_date': '01-09-2026',
          'qty': 2,
          'from_load_unit_id': box,
        });

        final cell = (await repo.cell(
          const CellRef(id: boxCell, address: 'A-1-1'),
        )).right.value!;
        final lu = cell.loadUnits.single;
        expect(lu.internalWarehouseId, isNull);
        expect(lu.lines.single.qty, 10);
        final loose = cell.loose.single;
        expect((loose.internalWarehouseId, loose.qty), (defectIwh, 2));
        expect(loose.internalWarehouseName, 'Брак');
      },
    );

    test('россыпь - основная и брак одной партии раздельно', () async {
      await pendingProblem({
        'good_id': good,
        'production_date': '02-09-2026',
        'qty': 1,
        'cell_id': looseCell,
      });

      final cell = (await repo.cell(
        const CellRef(id: looseCell, address: 'С-Н-П'),
      )).right.value!;
      expect(
        {for (final l in cell.loose) l.internalWarehouseId: l.qty},
        {null: 2, defectIwh: 1},
      );
    });
  });

  group('остатки по товарам из снимка (ADHOC-33)', () {
    setUp(() => cache.replace(fixture));

    test('товар: короб и россыпь сложены, склад «Основной» - null', () async {
      final viewed = await repo.goodsStock(
        refreshFailure: const Failure.network(),
      );
      final stock = viewed.value!.single;
      expect(stock.goodId, good);
      expect(stock.name, 'Кальмар');
      expect(stock.byWarehouse, {null: 15});
      expect(stock.qtyOn(const {}), 15);
      expect(stock.pending, isFalse);
      expect((viewed.freshness as FromSnapshot).offline, isTrue);
    });

    test('снимок обновлён - данные без подписи', () async {
      final viewed = await repo.goodsStock();
      expect(viewed.freshness, isA<FreshFromServer>());
    });

    test('места товара: ячейка, короб, партия; вдоль стеллажа', () async {
      final places = (await repo.goodPlaces(good)).value!;
      expect(
        [for (final p in places) (p.cellAddress, p.loadUnitId, p.qty)],
        [('A-1-1', box, 12.0), ('С-Н-П', null, 3.0)],
      );
      expect(places.first.productionDate, '01-09-2026');
      expect((await repo.goodPlaces('нет-такого')).value, isEmpty);
    });

    test(
      'своя пометка брака - остаток делится по складам, с пометкой',
      () async {
        await outbox.enqueue(
          kind: OutboxKind.problemSubmit,
          payload: {
            'problem_id': const Uuid().v4(),
            'warehouse_id': wh,
            'to_internal_warehouse_id': defectIwh,
            'reason': 'breakage',
            'good_id': good,
            'production_date': '01-09-2026',
            'qty': 2,
            'from_load_unit_id': box,
          },
        );

        final stock = (await repo.goodsStock()).value!.single;
        expect(stock.byWarehouse, {null: 13, defectIwh: 2});
        expect(stock.qtyOn(const {defectIwh}), 2);
        expect(stock.qtyOn(const {null}), 13);
        expect(stock.pending, isTrue);

        final defect = (await repo.goodPlaces(
          good,
        )).value!.singleWhere((p) => p.internalWarehouseId == defectIwh);
        expect((defect.cellAddress, defect.loadUnitId), ('A-1-1', null));
        expect(defect.internalWarehouseName, 'Брак');
      },
    );

    test(
      'своё перемещение россыпи в другую ячейку - место сменилось',
      () async {
        await outbox.enqueue(
          kind: OutboxKind.movementSubmit,
          payload: {
            'warehouse_id': wh,
            'lines': [
              {
                'good_id': good,
                'production_date': '02-09-2026',
                'qty': 3,
                'from_cell_id': looseCell,
                'to_cell_id': boxCell,
              },
            ],
          },
        );

        final places = (await repo.goodPlaces(good)).value!;
        expect(
          [for (final p in places) (p.cellAddress, p.loadUnitId, p.qty)],
          [('A-1-1', null, 3.0), ('A-1-1', box, 12.0)],
        );
        expect((await repo.goodsStock()).value!.single.qtyOn(const {}), 15);
      },
    );

    test(
      'короб целиком в брак своей очередью - его состав на «Браке»',
      () async {
        await outbox.enqueue(
          kind: OutboxKind.problemSubmit,
          payload: {
            'problem_id': const Uuid().v4(),
            'warehouse_id': wh,
            'to_internal_warehouse_id': defectIwh,
            'reason': 'breakage',
            'load_unit_id': box,
          },
        );
        final stock = (await repo.goodsStock()).value!.single;
        expect(stock.byWarehouse, {null: 3, defectIwh: 12});
      },
    );
  });

  group('вкладка «Короба» (P5-05-1)', () {
    /// Своя неотправленная приёмка: новый короб в ячейку приёмки.
    Future<void> pendingReceipt(String id) => outbox.enqueue(
      kind: OutboxKind.receiptSubmit,
      payload: {
        'warehouse_id': wh,
        'load_units': [
          {'id': id, 'kind': 'box'},
        ],
        'lines': [
          {
            'good_id': good,
            'production_date': '01-09-2026',
            'qty': 1,
            'load_unit_id': id,
          },
        ],
      },
    );

    test('список: снимок и своя приёмка поверх, с адресами и подписью', () async {
      await cache.replace(fixture);
      const own = '11111111-2222-4333-8444-555566667777';
      await pendingReceipt(own);

      final list = await repo.loadUnits(
        refreshFailure: const Failure.network(),
      );
      expect(list.value!.map((e) => e.id), [box, own]); // A-1-1 раньше С-Н-П
      expect(list.value![0].cellAddress, 'A-1-1');
      expect(list.value![1].cellAddress, 'С-Н-П');
      expect(list.value![1].pending, isTrue);
      expect((list.freshness as FromSnapshot).offline, isTrue);

      // ADHOC-22: снимок обновился - подписи нет; сервер ответил ошибкой - подпись без
      // «нет связи».
      expect((await repo.loadUnits()).freshness, isA<FreshFromServer>());
      final serverDown = await repo.loadUnits(
        refreshFailure: const Failure.server(500),
      );
      expect((serverDown.freshness as FromSnapshot).offline, isFalse);
    });

    test('поиск без связи - по хвосту id в снимке и своей очереди', () async {
      await cache.replace(fixture);
      const own = '11111111-2222-4333-8444-555566667777';
      await pendingReceipt(own);
      when(
        () => api.search(any()),
      ).thenAnswer((_) async => const Left(Failure.network()));

      final byFixture = (await repo.searchLoadUnits('9FA0')).right;
      expect(byFixture.value!.map((e) => e.id), [box]);
      expect(byFixture.freshness, isA<FromSnapshot>());

      final byOwn = (await repo.searchLoadUnits('66667777')).right;
      expect(byOwn.value!.single.id, own);
      expect(byOwn.value!.single.pending, isTrue);

      // Начало UUID в коротком коде не участвует - его нет на ярлыке.
      expect((await repo.searchLoadUnits('5A0C')).right.value, isEmpty);
    });

    test('сервер без ручки поиска (старая версия) - поиск по снимку', () async {
      await cache.replace(fixture);
      when(
        () => api.search(any()),
      ).thenAnswer((_) async => const Left(Failure.server(405)));

      final found = (await repo.searchLoadUnits('7B7A')).right;
      // Связь есть, сервер ответил кодом - снимок, но не «нет связи» (ADHOC-22).
      expect((found.freshness as FromSnapshot).offline, isFalse);
      expect((await repo.searchLoadUnits('9FA0')).right.value!.single.id, box);
    });

    test('истёкшая сессия - отказ, а не снимок', () async {
      when(
        () => api.search(any()),
      ).thenAnswer((_) async => const Left(Failure.auth()));

      expect((await repo.searchLoadUnits('9FA0')).left, isA<AuthFailure>());
    });

    test('поиск со связью - выдача сервера, неживой короб тоже', () async {
      when(() => api.search('9FA0')).thenAnswer(
        (_) async => const Right([LoadUnitView(id: box, live: false)]),
      );

      final found = (await repo.searchLoadUnits('9FA0')).right;
      expect(found.freshness, isA<FreshFromServer>());
      expect(found.value!.single.live, isFalse);
    });

    test('история - только по сети', () async {
      when(() => api.history(box)).thenAnswer(
        (_) async => Right(LoadUnitHistory(createdAt: DateTime(2026, 10, 8))),
      );

      expect((await repo.history(box)).isRight, isTrue);
      when(
        () => api.history(box),
      ).thenAnswer((_) async => const Left(Failure.network()));
      expect((await repo.history(box)).left, isA<NetworkFailure>());
    });
  });

  group('короб ЧЗ по SSCC (CZ-06)', () {
    const czCode = '00046012345678901234';

    test('эталон: код короба ЧЗ и марки снимка', () {
      expect(fixture.loadUnits.single.czCode, czCode);
      expect(fixture.loadUnits.single.czOpened, isFalse);
      final inBox = fixture.marks.firstWhere((m) => m.loadUnitId != null);
      expect(inBox.loadUnitId, box);
      expect(inBox.aggregateCode, czCode);
      expect(inBox.productionDate, '01-09-2026');
      final loose = fixture.marks.firstWhere((m) => m.cellId != null);
      expect(loose.cellId, looseCell);
      expect(loose.internalWarehouseId, mainIwh);
      expect(loose.aggregateCode, isNull);
    });

    test('со связью - ГЕ по ответу сервера', () async {
      when(() => api.cardByCzCode(czCode)).thenAnswer(
        (_) async =>
            const Right(LoadUnitView(id: box, live: true, czCode: czCode)),
      );
      expect((await repo.loadUnitIdByCzCode(czCode)).right, box);
    });

    test('сервер не знает короба - не принят', () async {
      when(
        () => api.cardByCzCode(czCode),
      ).thenAnswer((_) async => const Left(Failure.server(404)));
      expect((await repo.loadUnitIdByCzCode(czCode)).right, isNull);
    });

    test('без связи - по снимку, код и вскрытие в карточке', () async {
      when(
        () => api.cardByCzCode(any()),
      ).thenAnswer((_) async => const Left(Failure.network()));
      expect(
        (await repo.loadUnitIdByCzCode(czCode)).left,
        isA<NetworkFailure>(),
        reason: 'снимка ещё не было - узнать негде',
      );

      await cache.replace(fixture);
      expect((await repo.loadUnitIdByCzCode(czCode)).right, box);
      expect(
        (await repo.loadUnitIdByCzCode('00000000000000000001')).right,
        isNull,
      );
      final card = (await repo.loadUnit(box)).right.value!;
      expect(card.czCode, czCode);
      expect(card.isCzBox, isTrue);
    });

    test('короб ЧЗ своей неотправленной приёмки - по очереди', () async {
      when(
        () => api.cardByCzCode(any()),
      ).thenAnswer((_) async => const Left(Failure.network()));
      await outbox.enqueue(
        kind: OutboxKind.receiptSubmit,
        payload: {
          'warehouse_id': wh,
          'load_units': [
            {'id': box, 'kind': 'box', 'cz_code': czCode},
          ],
          'lines': [
            {
              'good_id': good,
              'production_date': '01-09-2026',
              'qty': 2,
              'load_unit_id': box,
            },
          ],
        },
      );
      expect((await repo.loadUnitIdByCzCode(czCode)).right, box);
      expect((await repo.loadUnit(box)).right.value!.czCode, czCode);
    });
  });

  group('марки на складе (CZ-06)', () {
    const boxMark = '0104601234567890215abcDEF';
    const looseMark = '0104601234567890215ghiJKL';
    const czCode = '00046012345678901234';

    test(
      'из снимка: марка по КИ, упаковка - её марки, склад «Основной» - null',
      () async {
        await cache.replace(fixture);
        final mark = (await repo.marksByCode(looseMark)).single;
        expect(mark.cellId, looseCell);
        expect(mark.internalWarehouseId, isNull);
        expect(mark.productionDate, '02-09-2026');
        // Код короба ЧЗ как упаковка: его марки.
        final inBox = (await repo.marksByCode(czCode)).single;
        expect(inBox.cis, boxMark);
        expect(inBox.loadUnitId, box);
        expect(await repo.marksByCode('0104600000000000215ZZ'), isEmpty);
      },
    );

    test(
      'своя неотправленная операция переносит марку и заводит новую',
      () async {
        await cache.replace(fixture);
        await outbox.enqueue(
          kind: OutboxKind.movementSubmit,
          payload: {
            'warehouse_id': wh,
            'lines': [
              {
                'good_id': good,
                'production_date': '01-09-2026',
                'qty': 1,
                'from_load_unit_id': box,
                'to_cell_id': looseCell,
                'marks': [boxMark],
              },
            ],
          },
        );
        await outbox.enqueue(
          kind: OutboxKind.receiptSubmit,
          payload: {
            'warehouse_id': wh,
            'load_units': const [],
            'lines': [
              {
                'good_id': good,
                'production_date': '03-09-2026',
                'qty': 1,
                'marks': [
                  {'cis': '0104601234567890215NEW'},
                ],
              },
            ],
          },
        );

        final moved = (await repo.marksByCode(boxMark)).single;
        expect(moved.loadUnitId, isNull);
        expect(moved.cellId, looseCell);
        expect(moved.pending, isTrue);
        final fresh = (await repo.marksByCode('0104601234567890215NEW')).single;
        expect(
          fresh.cellId,
          looseCell,
          reason: 'строка без ячейки - ячейка приёмки',
        );
        expect(fresh.productionDate, '03-09-2026');
      },
    );
  });

  test(
    'миграция 11 → 12: код короба ЧЗ, марки снимка, снимок перечитать',
    () async {
      await db.customStatement('DROP TABLE cached_cz_marks');
      await db.customStatement('DROP TABLE cached_load_units');
      await db.customStatement(
        'CREATE TABLE cached_load_units (id TEXT NOT NULL, kind TEXT NOT NULL, '
        'cell_id TEXT NOT NULL, created_at INTEGER NOT NULL, '
        "internal_warehouse_id TEXT NOT NULL DEFAULT '', PRIMARY KEY (id))",
      );
      await db
          .into(db.catalogSyncMarks)
          .insert(
            CatalogSyncMarksCompanion.insert(
              catalog: ContentsCache.markName,
              syncedAt: DateTime.utc(2026, 10, 8),
            ),
          );

      await db.migration.onUpgrade(Migrator(db), 11, 12);

      expect(
        await cache.asOf(),
        isNull,
        reason: 'в снимке нет марок и кодов коробов ЧЗ - перечитать',
      );
      await cache.replace(fixture);
      expect(
        (await cache.loadUnits([box]))[box]?.czCode,
        '00046012345678901234',
      );
      expect(await db.select(db.cachedCzMarks).get(), hasLength(2));
    },
  );

  test('короткий код: приведение и совпадение по хвосту', () {
    expect(shortCodeQuery(' 9fa0 b1c2 '), '9FA0B1C2');
    expect(shortCodeQuery('9fa0-b1'), '9FA0B1');
    expect(shortCodeQuery('XYZ'), isNull);
    expect(shortCodeQuery('123456789'), isNull);
    expect(shortCodeQuery(''), isNull);

    expect(matchesShortCode(box, '9FA0B1C2'), isTrue);
    expect(matchesShortCode(box, 'A0B1'), isTrue);
    expect(matchesShortCode(box, '5A0C'), isFalse);
  });
}
