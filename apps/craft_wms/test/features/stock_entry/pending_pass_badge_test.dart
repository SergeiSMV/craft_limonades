import 'dart:async';

import 'package:craft_wms/core/di/injection.dart';
import 'package:craft_wms/core/constants/app_colors.dart';
import 'package:craft_wms/core/gen/assets.gen.dart';
import 'package:craft_wms/core/widgets/notification_badge.dart';
import 'package:craft_wms/core/widgets/pending_pass_badge.dart';
import 'package:craft_wms/features/home/presentation/widgets/menu_tile.dart';
import 'package:craft_wms/features/stock_entry/data/entry_draft_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockDrafts extends Mock implements EntryDraftStore {}

/// Пометка незавершённого прохода на входах в раздел (ADHOC-13).
///
/// Просчитанные ячейки лежат в своей таблице и в очередь операций не попадают, поэтому индикатор
/// синхронизации (P2-07) их не видит: на устройстве может ждать обход всего склада, а шапка
/// показывает «всё отправлено». Пометка закрывает эту слепую зону.
///
/// Хранилище подменено намеренно. С настоящей drift-базой виджет-тест виснет: drift на отмену
/// подписки заводит таймер нулевой длительности, дерево разбирается уже после тела теста, и
/// проверка «нет висящих таймеров» крутит кадры до таймаута. Урок записан ещё в P2-06.
void main() {
  late _MockDrafts drafts;
  late StreamController<bool> hasDraft;

  setUp(() {
    drafts = _MockDrafts();
    hasDraft = StreamController<bool>.broadcast();
    when(() => drafts.watchHasDraft()).thenAnswer((_) => hasDraft.stream);
    if (getIt.isRegistered<EntryDraftStore>()) {
      getIt.unregister<EntryDraftStore>();
    }
    getIt.registerSingleton<EntryDraftStore>(drafts);
  });

  tearDown(() => hasDraft.close());

  Future<void> pump(WidgetTester tester) => tester.pumpWidget(
    const MaterialApp(
      home: Scaffold(
        body: Center(
          child: PendingPassBadge(child: SizedBox(width: 80, height: 80)),
        ),
      ),
    ),
  );

  testWidgets('прохода нет - пометки нет', (tester) async {
    await pump(tester);
    hasDraft.add(false);
    await tester.pump();

    expect(find.text('!'), findsNothing);
  });

  testWidgets('есть незавершённый проход - пометка видна', (tester) async {
    await pump(tester);
    hasDraft.add(true);
    await tester.pump();

    expect(find.text('!'), findsOneWidget);
  });

  // Проход отправлен или отброшен - пометка обязана исчезнуть сама, без пересборки экрана:
  // иначе она висела бы до следующего входа в приложение.
  testWidgets('проход убран - пометка гаснет живьём', (tester) async {
    await pump(tester);
    hasDraft.add(true);
    await tester.pump();
    expect(find.text('!'), findsOneWidget);

    hasDraft.add(false);
    // Два кадра: первый доставляет событие потока в StreamBuilder, второй перерисовывает.
    await tester.pump(Duration.zero);
    await tester.pump(Duration.zero);

    expect(find.text('!'), findsNothing);
  });

  // До первого значения мигнуть пометкой на пустом проходе хуже, чем показать её кадром позже.
  testWidgets('до первого значения пометки нет', (tester) async {
    await pump(tester);
    await tester.pump();

    expect(find.text('!'), findsNothing);
  });

  // Плитка рисует пометку САМА (`showBadge`), а не оборачивается снаружи. Первый заход обернул
  // плитку в Stack извне, и кружок уехал в зазор между плитками - плитка занимает всю ячейку
  // сетки, и подвесить что-то поверх её угла снаружи некуда.
  group('пометка на плитке меню', () {
    Future<void> pumpTile(
      WidgetTester tester, {
      required bool badge,
    }) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            // Ячейка заведомо шире содержимого: иначе плитка заполнит её и без
            // StackFit.expand, и дефект «сжалась по содержимому» не проявится.
            child: SizedBox(
              width: 300,
              height: 200,
              child: MenuTile(
                title: 'ШК',
                subtitle: 'коротко',
                imageIcon: Assets.icons.menuIcons.inbox,
                color: AppColors.kTileStock,
                showBadge: badge,
                onTap: () {},
              ),
            ),
          ),
        ),
      ),
    );

    testWidgets('без флага пометки нет', (tester) async {
      await pumpTile(tester, badge: false);

      expect(find.byType(NotificationBadge), findsNothing);
    });

    testWidgets('с флагом пометка внутри границ плитки', (tester) async {
      await pumpTile(tester, badge: true);

      expect(find.byType(NotificationBadge), findsOneWidget);

      // Главная проверка: кружок лежит ВНУТРИ прямоугольника плитки. Снаружи он висел бы
      // в зазоре сетки - так и выглядел первый заход.
      // Мерим КРАШЕНЫЙ прямоугольник плитки, а не MenuTile: MenuTile - это стопка, она
      // занимает всю ячейку всегда, и дефект «плитка сжалась по содержимому» по ней не виден.
      final tile = tester.getRect(find.byKey(MenuTile.surfaceKey));
      final badge = tester.getRect(find.byType(NotificationBadge));
      expect(
        tile.contains(badge.topLeft) && tile.contains(badge.bottomRight),
        isTrue,
        reason: 'пометка вышла за границы плитки: плитка $tile, пометка $badge',
      );
    });
  });
}
