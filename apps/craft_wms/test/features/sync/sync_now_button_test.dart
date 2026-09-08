import 'package:craft_wms/core/gen/strings.g.dart';
import 'package:craft_wms/core/outbox/outbox_repository.dart';
import 'package:craft_wms/core/sync/link_state.dart';
import 'package:craft_wms/core/sync/sync_engine.dart';
import 'package:craft_wms/features/sync/presentation/bloc/sync_status_cubit.dart';
import 'package:craft_wms/features/sync/presentation/widgets/sync_now_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockOutbox extends Mock implements OutboxRepository {}

class _MockEngine extends Mock implements SyncEngine {}

/// Кнопка ручной отправки очереди (P2-07).
void main() {
  late _MockOutbox outbox;
  late _MockEngine engine;
  late ValueNotifier<bool> syncing;

  setUp(() {
    LocaleSettings.useDeviceLocale();
    outbox = _MockOutbox();
    engine = _MockEngine();
    syncing = ValueNotifier(false);
    when(() => engine.link).thenReturn(ValueNotifier(LinkState.online));
    when(() => engine.syncing).thenReturn(syncing);
    when(() => outbox.watchPendingCount()).thenAnswer((_) => Stream.value(2));
    when(() => outbox.watchRejectedCount()).thenAnswer((_) => Stream.value(0));
  });

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: BlocProvider(
          create: (_) => SyncStatusCubit(outbox, engine),
          child: const Scaffold(floatingActionButton: SyncNowButton()),
        ),
      ),
    );
    await tester.pump();
  }

  /// Настроить исход прохода.
  void stubDrain({int sent = 0, int rejected = 0, int remaining = 0}) {
    when(() => engine.drain()).thenAnswer(
      (_) async =>
          SyncResult(sent: sent, rejected: rejected, remaining: remaining),
    );
  }

  testWidgets('нажатие запускает проход очереди', (tester) async {
    stubDrain(sent: 2);
    await pump(tester);

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pump();

    verify(() => engine.drain()).called(1);
  });

  // Три исхода, которые кладовщик обязан различать. Одно общее «готово» на все три означало
  // бы, что после «готово» очередь может остаться полной.
  testWidgets('всё ушло — сообщение с числом отправленных', (tester) async {
    stubDrain(sent: 2);
    await pump(tester);

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pump();
    await tester.pump();

    expect(find.text(t.syncQueue.syncResultSent(count: 2)), findsOneWidget);
  });

  testWidgets('часть застряла — сообщение про остаток, а не «готово»', (
    tester,
  ) async {
    stubDrain(sent: 1, remaining: 3);
    await pump(tester);

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pump();
    await tester.pump();

    expect(find.text(t.syncQueue.syncResultStuck(count: 3)), findsOneWidget);
  });

  testWidgets('сервер отклонил — говорим об этом отдельно', (tester) async {
    stubDrain(sent: 1, rejected: 2);
    await pump(tester);

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pump();
    await tester.pump();

    expect(find.text(t.syncQueue.syncResultRejected(count: 2)), findsOneWidget);
  });

  testWidgets('отправлять было нечего — так и говорим', (tester) async {
    stubDrain();
    await pump(tester);

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pump();
    await tester.pump();

    expect(find.text(t.syncQueue.syncResultNothing), findsOneWidget);
  });

  // Повторное нажатие упёрлось бы в защиту от повторного входа и вернуло «отправлено 0» —
  // ответ, который читается как «ничего не ушло». Та же ловушка, что чинилась в ADHOC-10.
  testWidgets('во время прохода кнопка погашена', (tester) async {
    stubDrain();
    syncing.value = true;
    await pump(tester);

    expect(find.text(t.syncQueue.syncRunning), findsOneWidget);
    final button = tester.widget<FloatingActionButton>(
      find.byType(FloatingActionButton),
    );
    expect(button.onPressed, isNull, reason: 'нажать нельзя, пока идёт проход');
  });
}
