import 'package:craft_wms/core/gen/strings.g.dart';
import 'package:craft_wms/core/theme/app_theme.dart';
import 'package:craft_wms/core/widgets/scan_field.dart';
import 'package:craft_wms/features/contents/domain/contents_entities.dart';
import 'package:craft_wms/features/movement/domain/movement_models.dart';
import 'package:craft_wms/features/movement/presentation/bloc/movement_state.dart';
import 'package:craft_wms/features/movement/presentation/widgets/move_hold_card.dart';
import 'package:craft_wms/features/movement/presentation/widgets/move_manual_pick.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// P6-04: карточка «в руках» и поле скана не переполняются на ширине ТСД. Найдено на DT50S:
// у короба в руках три кнопки в одну строку уезжали за край на 104 px. Ширины - настоящим
// Inter и темой приложения: тестовый шрифт шире почти вдвое.
void main() {
  setUp(LocaleSettings.useDeviceLocale);

  setUpAll(() async {
    final loader = FontLoader('Inter');
    for (final w in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
      loader.addFont(rootBundle.load('assets/fonts/Inter/Inter-$w.otf'));
    }
    await loader.load();
  });

  const box = MovePlace(
    cellId: 'c1',
    cellAddress: 'M1-5-3-3',
    loadUnitId: '00000000-0000-4000-8000-0000d35fae87',
  );
  const holds = <String, MoveHold>{
    'короб': MoveHold.source(place: box, contents: <ContentLine>[]),
    // Выбран вручную - четыре действия: товар, ячейка, перепечатать ярлык, положить обратно.
    'короб вручную': MoveHold.source(
      place: box,
      contents: <ContentLine>[],
      manual: true,
    ),
    'россыпь': MoveHold.source(
      place: MovePlace(cellId: 'c1', cellAddress: 'M1-5-3-3'),
      contents: <ContentLine>[],
    ),
    'товар': MoveHold.goods(
      good: MoveGood(id: 'g', name: 'Кальмар сушёный, 50 г', uom: 'шт'),
      productionDate: '01-09-2026',
      qty: 12,
      from: box,
    ),
  };

  testWidgets('без переполнения на ширине ТСД', (tester) async {
    // DT50S - 360 логических точек; 320 - с запасом на крупный шрифт системы.
    for (final width in [320.0, 360.0]) {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      for (final entry in holds.entries) {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ScanField(
                      controller: TextEditingController(),
                      focusNode: FocusNode(),
                      hint: t.movement.scanTargetHint,
                      onSubmitted: (_) {},
                    ),
                    MoveHoldCard(
                      hold: entry.value,
                      onChooseGood: () {},
                      onChooseCell: () {},
                      onFindBox: () {},
                      onReprint: () {},
                      onDrop: () {},
                    ),
                    MoveManualPick(onChooseCell: () {}, onFindBox: () {}),
                  ],
                ),
              ),
            ),
          ),
        );
        expect(
          tester.takeException(),
          isNull,
          reason: '${entry.key}, ширина $width',
        );
      }
    }
  });
}
