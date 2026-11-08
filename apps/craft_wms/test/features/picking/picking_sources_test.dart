import 'package:craft_wms/features/contents/domain/contents_entities.dart';
import 'package:craft_wms/features/picking/domain/picking_models.dart';
import 'package:craft_wms/features/picking/domain/picking_sources.dart';
import 'package:craft_wms/features/picking/domain/picking_view.dart';
import 'package:flutter_test/flutter_test.dart';

const _box = 'b0000000-0000-4000-8000-000000000001';

PickingOrderView _view({List<PickingPick> picks = const []}) =>
    PickingOrderView.build(
      PickingOrderDraft(
        order: PickingOrder(
          id: 'o1',
          number: 1,
          registryDate: '2026-11-09',
          status: PickingStatus.inProgress,
          mine: true,
          lines: const [
            PickingLine(
              id: 'l1',
              goodId: 'g1',
              goodName: 'Лимонад',
              uom: 'шт',
              planQty: 8,
              suggestion: PickingSuggestion(
                remaining: 8,
                takes: [
                  PickingTake(
                    cellId: 'c1',
                    cellAddress: 'A-1',
                    internalWarehouseId: 'w-main',
                    batchDate: '2026-10-01',
                    qty: 5,
                  ),
                  PickingTake(
                    cellId: 'c2',
                    cellAddress: 'B-1',
                    loadUnitId: _box,
                    batchDate: '2026-10-01',
                    qty: 20,
                  ),
                ],
              ),
            ),
            PickingLine(
              id: 'l2',
              goodId: 'g2',
              goodName: 'Вода',
              uom: 'шт',
              czMarked: true,
              batchDate: '2026-10-01',
              planQty: 2,
            ),
          ],
          picks: picks,
        ),
        fetchedAt: DateTime(2026, 11, 9),
      ),
      states: const {},
    );

StockMark _mark(String cis, {String good = 'g2', String? box}) => StockMark(
  cis: cis,
  goodId: good,
  productionDate: '01-10-2026',
  loadUnitId: box,
  cellId: box == null ? 'c1' : null,
);

/// Что взять по скану (P9-06): подбор сервера, снимок терминала, марки.
void main() {
  test('скан ячейки - россыпь из подбора, не больше остатка строки', () {
    final c = candidatesFromTakes(_view(), cellAddress: 'a-1').single;

    expect(c.sourceCellId, 'c1');
    expect(c.sourceLoadUnitId, isNull);
    expect(c.productionDate, '01-10-2026');
    expect(c.internalWarehouseId, 'w-main');
    expect(c.available, 5);
  });

  test('скан короба - короб из подбора; доступно не больше остатка', () {
    final c = candidatesFromTakes(_view(), loadUnitId: _box.toUpperCase());

    expect(c.single.sourceLoadUnitId, _box);
    expect(c.single.available, 8);
  });

  test('источник вне подбора - по снимку, минус «в сборке»', () {
    final c = candidatesFromContents(
      _view(),
      contents: const [
        ContentLine(
          goodId: 'g1',
          productionDate: '02-10-2026',
          qty: 20,
          inPicking: 18,
        ),
        ContentLine(goodId: 'g9', productionDate: '02-10-2026', qty: 5),
      ],
      cellAddress: 'C-1',
      cellId: 'c3',
    );

    expect(c.single.available, 2);
    expect(c.single.sourceCellId, 'c3');
    expect(c.single.internalWarehouseId, '');
  });

  test('марка - в маркируемую строку, источник - её место', () {
    final res = candidateFromMarks(
      _view(),
      found: [_mark('m1')],
      cellAddressOf: (_) => 'A-1',
    );

    expect(res.problem, isNull);
    expect(res.candidate!.line.id, 'l2');
    expect(res.candidate!.sourceCellId, 'c1');
    expect(res.marks, ['m1']);
  });

  test('упаковка больше нужного - только марками поштучно', () {
    final res = candidateFromMarks(
      _view(),
      found: [
        for (final m in ['m1', 'm2', 'm3']) _mark(m, box: _box),
      ],
      cellAddressOf: (_) => 'B-1',
    );

    expect(res.problem, MarkPickProblem.tooMany);
  });

  test('уже взятая марка второй раз не берётся', () {
    final view = _view(
      picks: const [
        PickingPick(
          id: 'p1',
          lineId: 'l2',
          boxId: 'x',
          productionDate: '01-10-2026',
          qty: 1,
          marks: ['m1'],
        ),
      ],
    );

    final res = candidateFromMarks(
      view,
      found: [_mark('m1')],
      cellAddressOf: (_) => 'A-1',
    );

    expect(res.problem, MarkPickProblem.already);
  });

  test('марки разных товаров и марка не из заказа - отказ', () {
    expect(
      candidateFromMarks(
        _view(),
        found: [
          _mark('m1'),
          _mark('m2', good: 'g1'),
        ],
        cellAddressOf: (_) => '',
      ).problem,
      MarkPickProblem.mixed,
    );
    expect(
      candidateFromMarks(
        _view(),
        found: [_mark('m1', good: 'g9')],
        cellAddressOf: (_) => '',
      ).problem,
      MarkPickProblem.noLine,
    );
  });
}
