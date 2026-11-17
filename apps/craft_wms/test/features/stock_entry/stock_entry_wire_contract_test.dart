import 'dart:convert';
import 'dart:io';

import 'package:craft_wms/core/database/app_database.dart';
import 'package:craft_wms/core/load_unit/load_unit_id_generator.dart';
import 'package:craft_wms/core/printer/printer_service.dart';
import 'package:craft_wms/features/cz/domain/cz_intake.dart';
import 'package:craft_wms/features/stock/data/catalog_models.dart';
import 'package:craft_wms/features/stock/data/catalog_repository.dart';
import 'package:craft_wms/features/stock_entry/data/entry_draft_store.dart';
import 'package:craft_wms/features/stock_entry/domain/stock_entry_repository.dart';
import 'package:craft_wms/features/stock_entry/presentation/bloc/stock_entry_cubit.dart';
import 'package:drift/native.dart';
import 'package:either_dart/either.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:uuid/data.dart';
import 'package:uuid/uuid.dart';

class _MockRepo extends Mock implements StockEntryRepository {}

class _MockCatalog extends Mock implements CatalogRepository {}

class _MockPrinter extends Mock implements PrinterService {}

/// Идентификаторы коробов по порядку - как в эталоне.
class _SequenceUuid extends Fake implements Uuid {
  _SequenceUuid(this._ids);

  final List<String> _ids;
  var _next = 0;

  @override
  String v4({Map<String, dynamic>? options, V4Options? config}) =>
      _ids[_next++];
}

/// Эталон тела checkpoint - общий с Go-тестом (`stock_entry_http_test.go`).
const _fixturePath =
    '../backend/internal/handler/testdata/stock_entry_checkpoint.json';

/// Dart-половина контракта ADHOC-46: тело checkpoint снимается с настоящего пути отправки
/// (cubit → репозиторий), а не собирается в тесте руками. Разойдись имя поля - упадёт этот тест
/// или его Go-половина.
void main() {
  test(
    'клиент шлёт ячейку с коробами и марками ровно в формате эталона',
    () async {
      final expected =
          jsonDecode(File(_fixturePath).readAsStringSync())
              as Map<String, dynamic>;
      final boxes = expected['load_units'] as List;
      final lines = expected['lines'] as List;
      Map<String, dynamic> line(int i) => lines[i] as Map<String, dynamic>;
      final ownBox = (boxes[0] as Map)['id'] as String;
      final czBox = boxes[1] as Map<String, dynamic>;
      final group = (expected['cz_groups'] as List).single as Map;

      final cell = Cell(
        id: expected['cell_id'] as String,
        warehouseId: 'w1',
        address: 'M1-1-1-1',
      );
      final lemon = Good(
        id: line(0)['good_id'] as String,
        name: 'Лимонад',
        uom: 'шт',
      );
      final beer = Good(
        id: line(2)['good_id'] as String,
        name: 'Пиво светлое',
        uom: 'шт',
        czMarked: true,
      );
      List<CzMarkDraft> marksOf(int i) => [
        for (final m in line(i)['marks'] as List)
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
      String uiDate(int i) =>
          (line(i)['production_date'] as String).replaceAll('-', '.');

      final repo = _MockRepo();
      when(
        () => repo.startSession(any()),
      ).thenAnswer((_) async => const Right('sess-1'));
      when(
        () => repo.checkpoint(
          sessionId: any(named: 'sessionId'),
          body: any(named: 'body'),
        ),
      ).thenAnswer((_) async => const Right(null));
      when(() => repo.finalize(any())).thenAnswer((_) async => const Right(1));
      when(() => repo.drainQueue()).thenAnswer((_) async => true);
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final cubit = StockEntryCubit(
        repo,
        _MockCatalog(),
        EntryDraftStore(db),
        LoadUnitIdGenerator(_SequenceUuid([ownBox, czBox['id'] as String])),
        _MockPrinter(),
      );
      addTearDown(cubit.close);

      cubit.selectCell(cell);
      await cubit.addLine(good: lemon, date: uiDate(0), qty: 4);
      final box = cubit.newBox();
      await cubit.addLine(good: lemon, date: uiDate(1), qty: 6, boxId: box);
      cubit.addCzBox(
        code: czBox['cz_code'] as String,
        lines: [CzIntakeLine(good: beer, date: uiDate(2), marks: marksOf(2))],
        groups: [
          CzGroupDraft(
            code: group['code'] as String,
            parentCode: group['parent_code'] as String,
          ),
        ],
      );
      cubit.addCzMarks(
        lines: [CzIntakeLine(good: beer, date: uiDate(3), marks: marksOf(3))],
      );
      cubit.finishCell();
      await cubit.finishSession();

      final body =
          verify(
                () => repo.checkpoint(
                  sessionId: 'sess-1',
                  body: captureAny(named: 'body'),
                ),
              ).captured.single
              as Map<String, dynamic>;
      expect(jsonDecode(jsonEncode(body)), expected);
      // Проход с марками перед финалом отправляет очередь: привязки ШК из марок - раньше финала.
      verify(() => repo.drainQueue()).called(1);
      expect(cubit.state.finished, isTrue);
    },
  );
}
