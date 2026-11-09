import 'dart:convert';
import 'dart:io';

import 'package:craft_wms/core/database/app_database.dart';
import 'package:craft_wms/features/contents/data/contents_cache.dart';
import 'package:craft_wms/features/contents/data/contents_dto.dart';
// Только Migrator: полный экспорт drift переопределяет матчеры теста.
import 'package:drift/drift.dart' show Migrator;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

const _fixturePath =
    '../backend/internal/handler/testdata/contents_snapshot.json';
const _looseCell = 'd0e1f2a3-b4c5-4d6e-8f70-8192a3b4c5d6';

/// «В сборке» у россыпи (P9-06): снимок и ответ ячейки несут `in_picking`, кэш его хранит.
void main() {
  late AppDatabase db;
  late ContentsCache cache;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    cache = ContentsCache(db);
  });

  tearDown(() => db.close());

  ContentsSnapshot snapshot({String inPicking = '2'}) {
    final json =
        jsonDecode(File(_fixturePath).readAsStringSync())
            as Map<String, dynamic>;
    for (final l in json['loose'] as List) {
      (l as Map<String, dynamic>)['in_picking'] = inPicking;
    }
    return ContentsSnapshot.fromJson(json);
  }

  test('эталон: in_picking россыпи разбирается', () {
    final fixture = ContentsSnapshot.fromJson(
      jsonDecode(File(_fixturePath).readAsStringSync()) as Map<String, dynamic>,
    );
    expect(fixture.loose.single.inPicking, 0);
    expect(snapshot().loose.single.inPicking, 2);
  });

  test('«в сборке» доходит из снимка до россыпи ячейки', () async {
    await cache.replace(snapshot());

    final loose = await cache.looseInCell(_looseCell);

    expect(loose.single.qty, 3);
    expect(loose.single.inPicking, 2);
  });

  test('россыпь ответа ячейки несёт «в сборке»', () {
    final cell = cellFromJson({
      'cell_id': _looseCell,
      'address': 'A-1',
      'loose': [
        {
          'good_id': 'g1',
          'production_date': '01-10-2026',
          'qty': '20',
          'in_picking': '5',
        },
      ],
    });

    expect(cell.loose.single.inPicking, 5);
  });

  test('миграция 13 → 14 добавляет колонку и сбрасывает снимок', () async {
    await cache.replace(snapshot());
    expect(await cache.asOf(), isNotNull);
    await db.customStatement(
      'ALTER TABLE cached_loose_stock DROP COLUMN in_picking',
    );

    await db.migration.onUpgrade(Migrator(db), 13, 14);

    expect(await cache.asOf(), isNull);
    expect((await cache.looseInCell(_looseCell)).single.inPicking, 0);
  });
}
