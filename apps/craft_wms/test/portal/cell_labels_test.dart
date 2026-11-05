import 'package:craft_wms/portal/domain/cells/cell_setup.dart';
import 'package:craft_wms/portal/domain/cells/cells_view.dart';
import 'package:craft_wms/portal/domain/labels/beam_label.dart';
import 'package:craft_wms/portal/domain/labels/code128.dart';
import 'package:flutter_test/flutter_test.dart';

CellSetup cell(
  String id,
  String address, {
  String? rack,
  bool floor = false,
  bool small = false,
  bool barcode = false,
  bool card = false,
}) => CellSetup(
  id: id,
  address: address,
  rackId: rack,
  rackCode: rack?.toUpperCase(),
  isFloor: floor,
  labelSmall: small,
  labelBarcode: barcode,
  sideCard: card,
);

/// ADHOC-57: образец этикетки совпадает с PDF бэкенда, порядок и сводные галочки страницы.
/// Эталонные числа сняты с `internal/labels` (Go) на тех же адресах.
void main() {
  group('Code128 — как у бэкенда', () {
    test('ширина в модулях', () {
      expect(code128Modules('B-1-1-12'), 123);
      expect(code128Modules('M1-10-3-7'), 134);
      expect(code128Modules('B-12-4-10'), 134);
      expect(
        code128Modules('С-Н-П'),
        isNull,
      ); // кириллица набором B не кодируется
    });

    test('штрихи', () {
      expect(code128Bars('B-1').take(5).toList(), [
        (0, 2),
        (3, 1),
        (6, 1),
        (11, 1),
        (15, 1),
      ]);
      expect(code128Bars('B-1').last, (66, 2));
    });
  });

  group('единый кегль — как beamSizes бэкенда', () {
    const set = [
      (address: 'B-1-1-12', floor: true),
      (address: 'B-12-4-10', floor: false),
    ];

    test(
      'большая балка со штрих-кодом ужимается по самому широкому адресу',
      () {
        final f = beamFont(BeamProfile.large, set, barcode: true);
        expect(f.capHeight, closeTo(14.9630, 1e-3));
        expect(f.fits, isTrue);
      },
    );

    test('без штрих-кода — потолок профиля', () {
      final f = beamFont(BeamProfile.large, const [
        (address: 'M1-10-3-7', floor: false),
      ], barcode: false);
      expect(f.capHeight, closeTo(26, 1e-6));
      expect(
        beamFont(BeamProfile.small, set, barcode: true).capHeight,
        closeTo(16, 1e-6),
      );
    });

    test('ниже capMin — кегль уменьшается шагом 1 пт, пока не влезет', () {
      const pt = 25.4 / 72;
      final p = BeamProfile.small;
      final f = beamFont(p, const [
        (address: 'ABCDEFGHIJKLMNOPQRSTUV-1-1', floor: true),
      ], barcode: true);
      expect(f.fits, isTrue);
      expect(f.capHeight, lessThan(p.capMin));
      final steps = (p.capMin / 0.718 - f.size) / pt;
      expect(steps, closeTo(steps.roundToDouble(), 1e-9));
    });

    test('код шире этикетки — fits = false', () {
      final f = beamFont(BeamProfile.small, [
        (address: '${'B-12-' * 12}1', floor: true),
      ], barcode: true);
      expect(f.fits, isFalse);
    });

    test('три части прижаты к полям, две — по центру', () {
      final p = BeamProfile.large;
      final three = beamLayout(p, 'B-1-1-12', 20, floor: true, barcode: true);
      expect(three.first.$2, p.pad);
      final arrow = three.last;
      expect(arrow.$2 + arrow.$3, closeTo(kLabelWidth - p.pad, 1e-9));
      final two = beamLayout(p, 'B-1-1-12', 20, floor: true, barcode: false);
      final left = two.first.$2;
      final right = kLabelWidth - (two.last.$2 + two.last.$3);
      expect(left, closeTo(right, 1e-9));
    });
  });

  group('CellsView', () {
    final view = CellsView(
      CellsSetup(
        warehouse: 'SHB',
        cells: [
          cell('a', 'B-1-1-2', rack: 'r2', card: true),
          cell(
            'b',
            'B-1-2-1',
            rack: 'r1',
            floor: true,
            barcode: true,
            card: true,
          ),
          cell('c', 'B-1-1-1', rack: 'r1', small: true, card: true),
          cell('d', 'Z-9', small: true),
          cell('e', 'B-1-1-10', rack: 'r1'),
        ],
        racks: const [
          Rack(id: 'r2', code: 'B-10'),
          Rack(id: 'r1', code: 'B-2'),
        ],
      ),
    );

    test(
      'порядок наклейки: стеллаж, позиция, ярусы сверху вниз; без стеллажа — в конце',
      () {
        expect(view.cells.map((c) => c.id), ['b', 'c', 'e', 'a', 'd']);
        expect(view.racks.map((r) => r.code), ['B-2', 'B-10']);
      },
    );

    test('фильтры', () {
      expect(view.filtered(const CellsFilter(query: 'b-1-1')).length, 3);
      expect(view.filtered(const CellsFilter(rackId: 'r1')).length, 3);
      expect(
        view
            .filtered(const CellsFilter(flag: FlagFilter.sideCard))
            .map((c) => c.id),
        ['b', 'c', 'a'],
      );
      expect(
        view.filtered(const CellsFilter(flag: FlagFilter.noBarcode)).length,
        4,
      );
      expect(
        view
            .filtered(const CellsFilter(beam: BeamFilter.small))
            .map((c) => c.id),
        ['c', 'd'],
      );
      expect(
        view
            .filtered(
              const CellsFilter(beam: BeamFilter.small),
              ignoreBeam: true,
            )
            .length,
        5,
      );
    });

    test('сводная галочка: у всех, ни у кого, у части', () {
      final r1 = view.filtered(const CellsFilter(rackId: 'r1'));
      final byId = {for (final c in view.cells) c.id: c};
      expect(view.aggregate(r1, CellFlag.sideCard), isNull);
      expect(view.aggregate(r1, CellFlag.floor), isNull);
      expect(
        view.aggregate([byId['b']!, byId['c']!], CellFlag.sideCard),
        isTrue,
      );
      expect(view.aggregate([byId['e']!], CellFlag.sideCard), isFalse);
    });

    test('«на карточке» — сводная только по ячейкам со стеллажом', () {
      final byId = {for (final c in view.cells) c.id: c};
      // d без стеллажа: у неё галочки не бывает, на сводную не влияет.
      expect(
        view.aggregate([byId['b']!, byId['d']!], CellFlag.sideCard),
        isTrue,
      );
      expect(view.aggregate([byId['d']!], CellFlag.sideCard), isFalse);
    });

    test('счётчики печати: карточка — на стеллаж с ячейками «на карточке»', () {
      final n = view.printCounts(view.cells);
      expect((n.large, n.small, n.cards), (3, 2, 2));
      final byId = {for (final c in view.cells) c.id: c};
      // Штрих-код на балке на карточку не влияет.
      expect(view.printCounts([byId['b']!]).cards, 1);
      expect(view.printCounts([byId['b']!, byId['c']!]).cards, 1);
      expect(view.printCounts([byId['e']!, byId['d']!]).cards, 0);
    });

    test('натуральный порядок', () {
      expect(naturalCompare('B-1-2-9', 'B-1-2-10'), lessThan(0));
      expect(naturalCompare('B-01', 'B-01'), 0);
    });
  });
}
