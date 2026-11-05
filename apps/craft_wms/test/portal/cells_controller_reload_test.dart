import 'package:craft_wms/portal/data/cells_repository.dart';
import 'package:craft_wms/portal/domain/cells/cell_setup.dart';
import 'package:craft_wms/portal/presentation/widgets/cells/cells_controller.dart';
import 'package:either_dart/either.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockRepo extends Mock implements CellsRepository {}

CellsSetup _setup(List<String> ids) => CellsSetup(
  warehouse: 'SHB',
  cells: [
    for (final id in ids)
      CellSetup(
        id: id,
        address: 'A-$id',
        rackId: null,
        rackCode: null,
        isFloor: false,
        labelSmall: false,
        labelBarcode: false,
        sideCard: false,
      ),
  ],
  racks: const [],
);

/// ADHOC-60: перечитывание «Ячеек» по версиям данных не сбивает несохранённые галочки.
void main() {
  late _MockRepo repo;
  late CellsController c;

  setUp(() async {
    repo = _MockRepo();
    when(repo.loadSetup).thenAnswer((_) async => Right(_setup(['c1', 'c2'])));
    c = CellsController(repo);
    await c.load();
  });

  tearDown(() => c.dispose());

  test(
    'без несохранённых галочек — перечитывает, выбор и фильтр живут',
    () async {
      c.focus('c1');
      c.setFilter(c.filter.copyWith(query: 'A'));
      when(
        repo.loadSetup,
      ).thenAnswer((_) async => Right(_setup(['c1', 'c2', 'c3'])));

      await c.reloadIfClean();

      expect(c.view!.cells, hasLength(3));
      expect(c.focusId, 'c1');
      expect(c.filter.query, 'A');
    },
  );

  test('с несохранёнными галочками — не перечитывает', () async {
    c.focus('c1');
    c.toggle(CellFlag.small);
    clearInteractions(repo);

    await c.reloadIfClean();

    verifyNever(repo.loadSetup);
    expect(c.draft, {CellFlag.small: true});
  });
}
