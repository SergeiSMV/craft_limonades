import 'package:craft_wms/portal/data/stocktakes_repository.dart';
import 'package:flutter_test/flutter_test.dart';

/// P10-05: дерево групп номенклатуры для выбора области — родитель, затем поддерево, по имени.
void main() {
  test('группы — обходом дерева с глубиной', () {
    final flat = flattenGroups([
      {'id': 'snacks', 'name': 'Снеки', 'parent_id': 'matrix'},
      {'id': 'matrix', 'name': '4/ Матрица РЫБА-СНЭКИ', 'parent_id': null},
      {'id': 'drinks', 'name': '1/ Напитки', 'parent_id': null},
      {'id': 'fish', 'name': 'Рыба', 'parent_id': 'matrix'},
    ]);
    expect(
      [for (final g in flat) '${g.depth}:${g.id}'],
      ['0:drinks', '0:matrix', '1:fish', '1:snacks'],
    );
  });
}
