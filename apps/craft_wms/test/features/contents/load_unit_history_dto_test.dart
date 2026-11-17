import 'package:craft_wms/features/contents/data/contents_dto.dart';
import 'package:craft_wms/features/contents/domain/contents_entities.dart';
import 'package:flutter_test/flutter_test.dart';

/// ADHOC-32: история короба несёт изменения состава; старый сервер их не отдаёт - пусто.
void main() {
  test('состав в истории: доложили из короба, вынули в ячейку, отгрузили', () {
    final h = historyFromJson({
      'load_unit_id': 'lu',
      'created_at': '2026-10-21T08:00:00Z',
      'receipt': null,
      'moves': [],
      'contents': [
        {
          'kind': 'in',
          'good_name': 'Кальмар',
          'uom': 'шт',
          'production_date': '01-09-2026',
          'qty': '2.000',
          'peer': 'M1-1-1-1',
          'peer_load_unit_id': '6f1c2b3a-0d4e-4f5a-8b6c-7d8e9fa0b1c2',
          'user_name': 'Иванов',
          'at': '2026-10-21T09:00:00Z',
        },
        {
          'kind': 'return',
          'good_name': 'Кальмар',
          'uom': 'шт',
          'production_date': '01-09-2026',
          'qty': 3,
          'peer': null,
          'at': '2026-10-21T10:00:00Z',
        },
        {'kind': 'future_kind', 'qty': '1', 'at': '2026-10-21T11:00:00Z'},
      ],
    });
    expect(h.contents.map((c) => c.kind), [
      LoadUnitContentKind.added,
      LoadUnitContentKind.returned,
      LoadUnitContentKind.other,
    ]);
    expect(h.contents.first.qty, 2);
    expect(h.contents.first.peerLoadUnitId, isNotNull);
    expect(h.contents[1].peer, isNull);
  });

  test('сервер до ADHOC-32: состава в ответе нет - история без него', () {
    final h = historyFromJson({
      'created_at': '2026-10-21T08:00:00Z',
      'moves': [],
    });
    expect(h.contents, isEmpty);
  });
}
