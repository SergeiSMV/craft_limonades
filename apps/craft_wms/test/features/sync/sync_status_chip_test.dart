import 'package:craft_wms/core/outbox/outbox_repository.dart';
import 'package:craft_wms/core/sync/link_state.dart';
import 'package:craft_wms/core/sync/sync_engine.dart';
import 'package:craft_wms/features/sync/presentation/bloc/sync_status_cubit.dart';
import 'package:craft_wms/features/sync/presentation/widgets/sync_status_chip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockOutbox extends Mock implements OutboxRepository {}

class _MockEngine extends Mock implements SyncEngine {}

/// Значок очереди и связи в шапке (P2-07).
void main() {
  late _MockOutbox outbox;
  late _MockEngine engine;

  setUp(() {
    outbox = _MockOutbox();
    engine = _MockEngine();
    when(() => engine.link).thenReturn(ValueNotifier(LinkState.online));
    when(() => engine.syncing).thenReturn(ValueNotifier(false));
  });

  Future<void> pump(
    WidgetTester tester, {
    required int pending,
    required int rejected,
    VoidCallback? onTap,
  }) async {
    when(
      () => outbox.watchPendingCount(),
    ).thenAnswer((_) => Stream.value(pending));
    when(
      () => outbox.watchRejectedCount(),
    ).thenAnswer((_) => Stream.value(rejected));
    await tester.pumpWidget(
      MaterialApp(
        home: BlocProvider(
          create: (_) => SyncStatusCubit(outbox, engine),
          child: Scaffold(
            appBar: AppBar(actions: [SyncStatusChip(onTap: onTap ?? () {})]),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('пустая очередь — тихая галочка без числа', (tester) async {
    await pump(tester, pending: 0, rejected: 0);

    expect(find.byIcon(Icons.cloud_done_outlined), findsOneWidget);
    expect(
      find.text('0'),
      findsNothing,
      reason: 'ноль на значке — шум: и так видно, что всё отправлено',
    );
  });

  testWidgets('ожидающие показаны числом', (tester) async {
    await pump(tester, pending: 3, rejected: 0);

    expect(find.byIcon(Icons.cloud_upload_outlined), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
  });

  testWidgets('отклонённые перебивают вид и считаются вместе с ждущими', (
    tester,
  ) async {
    await pump(tester, pending: 3, rejected: 2);

    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(
      find.text('5'),
      findsOneWidget,
      reason: 'на значке — вся очередь, а не одна её половина',
    );
  });

  // Показать «3 ждут» и не дать ничего с этим сделать — тревога без выхода.
  testWidgets('нажатие ведёт на разбор', (tester) async {
    var tapped = 0;
    await pump(tester, pending: 1, rejected: 0, onTap: () => tapped++);

    await tester.tap(find.byType(SyncStatusChip));
    await tester.pump();

    expect(tapped, 1);
  });
}
