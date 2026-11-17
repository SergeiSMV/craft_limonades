import 'package:craft_wms/features/tasks/domain/tasks_models.dart';

/// Ответ `GET /tasks` в том виде, в каком его отдаёт сервер (handler/tasks.go): количества -
/// строкой, даты партий - DD-MM-YYYY, у короба - состав, у россыпи - товар и остаток.
const serverTaskJson = <String, dynamic>{
  'id': '11111111-1111-4111-8111-111111111111',
  'number': 57,
  'kind': 'putaway',
  'status': 'new',
  'warehouse_id': '22222222-2222-4222-8222-222222222222',
  'receipt_id': '33333333-3333-4333-8333-333333333333',
  'supplier': 'ООО «Голсера»',
  'received_at': '2026-10-07T11:30:00Z',
  'assignee_name': '',
  'taken_at': null,
  'created_at': '2026-10-07T11:30:00Z',
  'items': [
    {
      'line_no': 1,
      'load_unit_id': '550e8400-e29b-41d4-a716-446655440000',
      'contents': [
        {
          'good': {'id': 'g1', 'code': '16121', 'name': 'Кальмар', 'uom': 'шт'},
          'production_date': '01-09-2026',
          'qty': '12',
        },
      ],
      'placed': false,
    },
    {
      'line_no': 2,
      'good': {'id': 'g1', 'code': '16121', 'name': 'Кальмар', 'uom': 'шт'},
      'production_date': '02-09-2026',
      'qty': '5',
      'remaining': '3',
      'placed': false,
    },
  ],
};

WarehouseTask serverTask() => WarehouseTask.fromJson(serverTaskJson);

/// Запись ленты с заданным моментом завершения.
CompletedTask completed(String id, String completedAt) => CompletedTask(
  id: id,
  number: 1,
  kind: TaskKind.putaway,
  completedAt: completedAt,
);
