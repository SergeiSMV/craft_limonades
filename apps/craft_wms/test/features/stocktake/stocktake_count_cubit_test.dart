import 'dart:convert';
import 'dart:io';

import 'package:craft_wms/core/error/failure.dart';
import 'package:craft_wms/features/stocktake/domain/stocktake_count.dart';
import 'package:craft_wms/features/stocktake/domain/stocktake_models.dart';
import 'package:craft_wms/features/stocktake/domain/stocktake_repository.dart';
import 'package:craft_wms/features/stocktake/presentation/bloc/stocktake_count_cubit.dart';
import 'package:either_dart/either.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockRepo extends Mock implements StocktakeRepository {}

/// Эталон формата — тот же файл, что применяет настоящий роутер сервера (P10-04).
const _fixturePath =
    '../backend/internal/handler/testdata/stocktake_cell_submit.json';

/// P10-04: подсчёт ячейки пересчёта на ТСД — слепой счёт, черновик, отправка.
void main() {
  late _MockRepo repo;

  const lemonade = StocktakeGood(
    id: '7f000000-0000-4000-8000-0000000000b1',
    name: 'Лимонад',
    uom: 'шт',
  );
  const snack = StocktakeGood(
    id: '7f000000-0000-4000-8000-0000000000b2',
    name: 'Снек',
    uom: 'шт',
  );
  const box = '7f000000-0000-4000-8000-0000000000c1';
  const lostBox = '7f000000-0000-4000-8000-0000000000c2';
  const defect = 'iwh-defect';
  final started = DateTime.utc(2026, 10, 26, 9);

  // Идентификатор ячейки пересчёта выдаёт сервер — в эталоне на его месте `CELL`.
  final view = StocktakeCellView(
    cell: StocktakeCell(
      id: 'CELL',
      stocktakeId: 'ST',
      cellId: 'c1',
      address: 'M1-1-1-1',
      status: StocktakeCellStatus.counting,
      startedAt: started,
      mine: true,
    ),
    positions: const [
      StocktakePosition(kind: StocktakePositionKind.box, loadUnitId: box),
      StocktakePosition(kind: StocktakePositionKind.box, loadUnitId: lostBox),
      StocktakePosition(
        kind: StocktakePositionKind.loose,
        good: lemonade,
        productionDate: '01-01-2026',
      ),
      StocktakePosition(
        kind: StocktakePositionKind.loose,
        good: lemonade,
        productionDate: '01-01-2026',
        internalWarehouseId: defect,
      ),
    ],
  );

  setUpAll(() => registerFallbackValue(<String, dynamic>{}));

  setUp(() {
    repo = _MockRepo();
    when(() => repo.loadDraft(any())).thenAnswer((_) async => null);
    when(() => repo.saveDraft(any(), any())).thenAnswer((_) async {});
  });

  StocktakeCountCubit cubit() => StocktakeCountCubit(repo, view);

  test('клиент собирает подсчёт ровно в формате эталона', () async {
    final fixture =
        jsonDecode(File(_fixturePath).readAsStringSync())
            as Map<String, dynamic>;
    final expected =
        ((fixture['operations'] as List).single
            as Map<String, dynamic>)['payload'];
    final c = cubit();

    // Тем же путём, что кладовщик: короб — сканом, россыпь — количеством, марка — сканом.
    c.foundBox(box.toUpperCase()); // регистр со скана не важен
    c.addQty(good: lemonade, productionDate: '01-01-2026', qty: 2);
    c.addQty(good: lemonade, productionDate: '01-01-2026', qty: 1);
    c.addMarks(
      good: snack,
      productionDate: '01-02-2026',
      marks: ['0104600000000017215S1'],
    );

    expect(
      jsonDecode(jsonEncode(c.state.count.payload())),
      expected,
      reason: 'формат разошёлся с testdata/stocktake_cell_submit.json',
    );
    await c.close();
  });

  test(
    'не найденное — короба и россыпь без насчитанного; излишек — отдельно',
    () async {
      final c = cubit();
      c.foundBox(box);
      c.addQty(good: lemonade, productionDate: '01-01-2026', qty: 4);
      c.addQty(good: lemonade, productionDate: '02-02-2026', qty: 1);
      final count = c.state.count;
      expect(count.missing.map((p) => p.loadUnitId ?? p.internalWarehouseId), [
        lostBox,
        defect,
      ]);
      expect(count.extraLines.single.productionDate, '02-02-2026');
      await c.close();
    },
  );

  test('короб не по учёту — найден с пометкой, повтор — подсказка', () async {
    final c = cubit();
    c.foundBox('7f000000-0000-4000-8000-0000000000ff');
    expect(c.state.notice, CountNotice.boxForeign);
    expect(c.state.count.foreignBoxes, hasLength(1));
    c.clearNotice();
    c.foundBox(box);
    c.foundBox(box);
    expect(c.state.notice, CountNotice.boxAgain);
    await c.close();
  });

  test('марка дважды не считается; количество марок — их число', () async {
    final c = cubit();
    c.addMarks(good: snack, productionDate: '01-02-2026', marks: ['M1', 'M2']);
    c.addMarks(good: snack, productionDate: '01-02-2026', marks: ['M2']);
    expect(c.state.notice, CountNotice.markAgain);
    expect(c.state.count.lines.single.qty, 2);
    await c.close();
  });

  test(
    '«Отменить» возвращает прежнее; правка партии переносит насчитанное',
    () async {
      final c = cubit();
      c.addQty(good: lemonade, productionDate: '01-01-2026', qty: 3);
      c.addQty(good: lemonade, productionDate: '01-01-2026', qty: 2);
      expect(c.state.count.lines.single.qty, 5);
      c.undo();
      expect(c.state.count.lines.single.qty, 3);
      c.editLine(
        c.state.count.lines.single,
        productionDate: '05-01-2026',
        qty: 3,
      );
      expect(c.state.count.lines.single.productionDate, '05-01-2026');
      expect(
        c.state.count.missing,
        hasLength(4),
        reason: 'два короба и обе позиции 01-01 — не найдены',
      );
      await c.close();
    },
  );

  test('черновик подхватывается только от того же снимка', () async {
    final same = StocktakeCount(
      view: view,
      lines: const [
        CountLine(good: lemonade, productionDate: '01-01-2026', qty: 7),
      ],
    );
    when(
      () => repo.loadDraft('CELL'),
    ).thenAnswer((_) async => _json(same.toJson()));
    final c = cubit();
    await c.restore();
    expect(c.state.count.lines.single.qty, 7);
    await c.close();

    final older = same.copyWith(
      view: view.copyWith(
        cell: view.cell.copyWith(
          startedAt: started.subtract(const Duration(hours: 1)),
        ),
      ),
    );
    when(
      () => repo.loadDraft('CELL'),
    ).thenAnswer((_) async => _json(older.toJson()));
    final fresh = cubit();
    await fresh.restore();
    expect(
      fresh.state.count.lines,
      isEmpty,
      reason: 'ячейку начали заново — снимок другой',
    );
    await fresh.close();
  });

  test('итог отправки: проведён, в очереди, отклонён', () async {
    for (final (res, outcome) in [
      (const Right<Failure, void>(null), CountOutcome.posted),
      (const Left<Failure, void>(Failure.network()), CountOutcome.queued),
      (
        const Left<Failure, void>(Failure.rejected('ячейку сбили')),
        CountOutcome.rejected,
      ),
    ]) {
      when(() => repo.submit(any(), any())).thenAnswer((_) async => res);
      final c = cubit();
      await c.submit();
      expect(c.state.outcome, outcome);
      if (outcome == CountOutcome.rejected) {
        expect(c.state.rejectReason, 'ячейку сбили');
      }
      await c.close();
    }
  });
}

/// Черновик лежит в базе строкой JSON — по тому же пути, что в жизни.
Map<String, dynamic> _json(Map<String, dynamic> m) =>
    jsonDecode(jsonEncode(m)) as Map<String, dynamic>;
