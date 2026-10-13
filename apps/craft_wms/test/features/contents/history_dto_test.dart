import 'package:craft_wms/features/contents/data/contents_dto.dart';
import 'package:craft_wms/features/contents/domain/contents_entities.dart';
import 'package:flutter_test/flutter_test.dart';

/// История короба из ответа сервера (P5-05-1): источник переноса различается по операции.
/// P6-04, найдено на DT50S: перемещение подписывалось «Размещением» — терминал различал
/// только «приёмка / не приёмка».
void main() {
  test('источник переноса: приёмка, размещение, перемещение и неизвестный', () {
    Map<String, dynamic> move(String source) => {
      'from': 'A',
      'to': 'B',
      'source': source,
      'at': '2026-10-13T15:50:00Z',
    };
    final history = historyFromJson({
      'created_at': '2026-10-05T10:58:00Z',
      'moves': [
        move('receipt'),
        move('putaway'),
        move('move'),
        move('shipment'),
      ],
    });

    expect(history.moves.map((m) => m.kind), [
      LoadUnitMoveKind.receipt,
      LoadUnitMoveKind.putaway,
      LoadUnitMoveKind.move,
      LoadUnitMoveKind.other,
    ]);
  });
}
