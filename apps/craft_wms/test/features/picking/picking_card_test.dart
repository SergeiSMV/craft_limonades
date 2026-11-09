import 'package:craft_wms/core/gen/strings.g.dart';
import 'package:craft_wms/features/picking/domain/picking_card.dart';
import 'package:craft_wms/features/picking/presentation/widgets/picking_card_format.dart';
import 'package:flutter_test/flutter_test.dart';

/// Ответ `GET /picking/orders/{id}/card` (ADHOC-62) - те же поля, что окно деталей портала
/// (`pickingPortalDetailDTO` бэкенда): количества приходят строкой decimal.
Map<String, dynamic> _json() => {
  'id': 'o1',
  'number': 6,
  'registry_date': '2026-10-31',
  'invoice_number': '21048',
  'order_number': '15787',
  'order_date': null,
  'direction': 'Клин',
  'client': 'Махатадзе М. ИП',
  'address': 'Клин, ул. Ленина, 1',
  'status': 'shipped',
  'is_partial': true,
  'has_unknown': false,
  'deleted': false,
  'changed_after_shipment': false,
  'assignee_name': '',
  'taken_at': null,
  'picked_by_name': 'Иванов И.',
  'picked_at': '2026-10-31T09:10:00Z',
  'shipped_at': '2026-10-31T10:00:00Z',
  'lines': 2,
  'plan_qty': 15,
  'fact_qty': '12',
  'boxes': 2,
  'return_left': '0',
  'items': [
    {
      'id': 'l1',
      'line_no': 1,
      'good_code': '00000016147',
      'good_name': 'Лимонад',
      'uom': 'шт',
      'cz_marked': false,
      'batch_date': '2026-10-01',
      'registry_cell': 'А-1-1',
      'cell_address': 'А-1-1',
      'plan_qty': 10,
      'fact_qty': '10',
      'removed': false,
      'shortage': false,
      'facts': [
        {
          'batch_date': '2026-10-01',
          'cell_address': 'А-1-1',
          'box_seq': 1,
          'qty': '6',
          'state': 'moved',
          'picked_by': 'Иванов И.',
          'picked_at': '2026-10-31T09:00:00Z',
          'marks': <String>[],
        },
        {
          'batch_date': '2026-10-05',
          'cell_address': 'А-1-2',
          'box_seq': 2,
          'qty': '4',
          'state': 'moved',
          'picked_by': 'Иванов И.',
          'picked_at': '2026-10-31T09:01:00Z',
          'marks': <String>[],
        },
      ],
    },
    {
      'id': 'l2',
      'line_no': 2,
      'good_code': '00000000002',
      'good_name': 'Пиво',
      'uom': 'шт',
      'cz_marked': true,
      'batch_date': null,
      'registry_cell': '',
      'cell_address': '',
      'plan_qty': 5,
      'fact_qty': '2',
      'removed': false,
      'shortage': true,
      'facts': [
        {
          'batch_date': '2026-09-20',
          'cell_address': 'Б-1-1',
          'box_seq': 2,
          'qty': '2',
          'state': 'moved',
          'picked_by': 'Иванов И.',
          'picked_at': '2026-10-31T09:02:00Z',
          'marks': ['m1', 'm2'],
        },
      ],
    },
  ],
  'box_list': [
    {'seq': 1, 'shipped_at': '2026-10-31T10:00:00Z'},
    {'seq': 2, 'shipped_at': '2026-10-31T10:00:00Z'},
  ],
  'changes': <Object>[],
  'events': [
    {
      'kind': 'taken',
      'user_name': 'Иванов И.',
      'prev_name': '',
      'boxes': null,
      'qty': null,
      'at': '2026-10-31T08:00:00Z',
    },
    {
      'kind': 'completed',
      'user_name': 'Иванов И.',
      'prev_name': '',
      'boxes': 2,
      'qty': '12',
      'at': '2026-10-31T09:10:00Z',
    },
    {
      'kind': 'shipped',
      'user_name': 'Петров П.',
      'prev_name': '',
      'boxes': 2,
      'qty': '12',
      'at': '2026-10-31T10:00:00Z',
    },
  ],
};

void main() {
  setUpAll(() => LocaleSettings.setLocale(AppLocale.ru));

  test('карточка: разбор ответа, кто отгрузил, нехватка, состав коробов', () {
    final c = PickingCard.fromJson(_json());
    expect(c.shipped, isTrue);
    expect(c.factQty, 12);
    expect(c.shippedBy, 'Петров П.');
    expect(c.items[0].missing, 0);
    expect(c.items[1].missing, 3);
    expect(c.items[1].marks, ['m1', 'm2']);
    expect(c.events[0].qty, 0);
    expect(c.boxContent(1).map((e) => e.fact.qty), [6]);
    expect(c.boxContent(2).map((e) => e.line.id), ['l1', 'l2']);
  });

  test('подписи: факт по партиям, «не хватает», состав короба, журнал', () {
    final c = PickingCard.fromJson(_json());
    final header = cardHeaderLines(c);
    expect(header, contains('Собрал: Иванов И.'));
    expect(header, contains('Отгрузил: Петров П.'));
    expect(header, contains('Отгружен частично'));
    expect(header, contains('Собрано всего: 12 из 15'));

    expect(cardLineLines(c.items[0]), [
      'План: 10 шт',
      'Партия по плану: 01.10.2026',
      'Ячейка реестра: А-1-1',
      'Собрано: 10 шт',
      'Партия 01.10.2026: 6 шт',
      'Партия 05.10.2026: 4 шт',
    ]);
    expect(cardLineNote(c.items[0]), isNull);
    expect(cardLineNote(c.items[1]), 'Не хватает: 3 шт');

    final box2 = cardBoxLines(c, c.boxList[1]);
    expect(box2.take(4), [
      '00000016147 Лимонад',
      'Партия 05.10.2026: 4 шт',
      '00000000002 Пиво',
      'Партия 20.09.2026: 2 шт',
    ]);
    expect(
      cardEventLine(c.events.last),
      endsWith('Отгрузил: Петров П., коробов 2, 12 шт.'),
    );
  });
}
