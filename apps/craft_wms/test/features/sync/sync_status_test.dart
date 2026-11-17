import 'package:craft_wms/core/outbox/outbox_repository.dart';
import 'package:craft_wms/core/sync/link_state.dart';
import 'package:craft_wms/core/sync/sync_engine.dart';
import 'package:craft_wms/features/sync/presentation/bloc/sync_status_cubit.dart';
import 'package:craft_wms/features/sync/presentation/bloc/sync_status_state.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockOutbox extends Mock implements OutboxRepository {}

class _MockEngine extends Mock implements SyncEngine {}

/// Индикатор синхронизации (P2-07): какой сигнал показывать и откуда он берётся.
void main() {
  group('правило приоритета сигнала', () {
    test('пустая очередь - всё отправлено', () {
      expect(const SyncStatusState().badge, SyncBadge.allSent);
    });

    test('ожидающие - «ждёт отправки»', () {
      expect(const SyncStatusState(pending: 3).badge, SyncBadge.waiting);
    });

    test(
      'идущая отправка важнее ожидания: она объясняет движение счётчика',
      () {
        expect(
          const SyncStatusState(pending: 3, syncing: true).badge,
          SyncBadge.sending,
        );
      },
    );

    // Отклонённые не уйдут сами. Пока их не разобрали, «всё отправлено» было бы неправдой,
    // а «отправляю» - обещанием, которого никто не выполнит.
    test('отклонённые важнее всего, даже во время отправки', () {
      expect(
        const SyncStatusState(pending: 3, rejected: 1, syncing: true).badge,
        SyncBadge.needsAttention,
      );
    });

    test('на значке - общее число строк очереди', () {
      expect(const SyncStatusState(pending: 3, rejected: 2).total, 5);
    });
  });

  group('пометка «нет связи»', () {
    // Показываем её только там, где она что-то объясняет.
    test('при непустой очереди - показываем', () {
      expect(
        const SyncStatusState(pending: 1, link: LinkState.offline).showOffline,
        isTrue,
      );
    });

    test('при пустой очереди молчим: отправлять всё равно нечего', () {
      expect(
        const SyncStatusState(link: LinkState.offline).showOffline,
        isFalse,
      );
    });

    test('про unknown молчим всегда: обменов не было, утверждать нечего', () {
      expect(
        const SyncStatusState(pending: 1).showOffline,
        isFalse,
        reason: 'иначе «нет связи» показывалось бы там, где мы не пробовали',
      );
    });
  });

  group('cubit сводит источники', () {
    late _MockOutbox outbox;
    late _MockEngine engine;
    late ValueNotifier<LinkState> link;
    late ValueNotifier<bool> syncing;

    setUp(() {
      outbox = _MockOutbox();
      engine = _MockEngine();
      link = ValueNotifier(LinkState.unknown);
      syncing = ValueNotifier(false);
      when(() => engine.link).thenReturn(link);
      when(() => engine.syncing).thenReturn(syncing);
      when(() => outbox.watchPendingCount()).thenAnswer((_) => Stream.value(2));
      when(
        () => outbox.watchRejectedCount(),
      ).thenAnswer((_) => Stream.value(1));
    });

    test('счётчики приезжают из очереди', () async {
      final cubit = SyncStatusCubit(outbox, engine);
      await Future<void>.delayed(Duration.zero);

      expect(cubit.state.pending, 2);
      expect(cubit.state.rejected, 1);
      await cubit.close();
    });

    // Состояние берётся ИЗ ДВИЖКА, а не из состояния виджета: проход, запущенный автоматически
    // (вход, событие сети, таймер), обязан быть виден экрану, собранному посреди него.
    test('текущее состояние движка видно сразу при создании', () async {
      syncing.value = true;
      link.value = LinkState.offline;

      final cubit = SyncStatusCubit(outbox, engine);

      expect(cubit.state.syncing, isTrue);
      expect(cubit.state.link, LinkState.offline);
      await cubit.close();
    });

    test('изменение связи доезжает до состояния', () async {
      final cubit = SyncStatusCubit(outbox, engine);
      await Future<void>.delayed(Duration.zero);

      link.value = LinkState.online;

      expect(cubit.state.link, LinkState.online);
      await cubit.close();
    });

    // Слушатель, переживший close, вызвал бы emit на закрытом cubit - а это исключение
    // в тот момент, когда экран уже ушёл и поймать его некому.
    test('после close изменение движка ничего не роняет', () async {
      final cubit = SyncStatusCubit(outbox, engine);
      await Future<void>.delayed(Duration.zero);
      await cubit.close();

      expect(() {
        link.value = LinkState.offline;
        syncing.value = true;
      }, returnsNormally);
    });
  });
}
