import 'package:craft_wms/core/error/failure.dart';
import 'package:craft_wms/core/printer/badge_label.dart';
import 'package:craft_wms/core/printer/printer_device.dart';
import 'package:craft_wms/core/printer/printer_service.dart';
import 'package:craft_wms/features/badges/domain/badge_holder.dart';
import 'package:craft_wms/features/badges/domain/badges_repository.dart';
import 'package:craft_wms/features/badges/presentation/bloc/badges_cubit.dart';
import 'package:either_dart/either.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockRepo extends Mock implements BadgesRepository {}

class _MockPrinter extends Mock implements PrinterService {}

class _FakeLabel extends Fake implements BadgeLabel {}

/// «Бейджи» на ТСД (ADHOC-65): список с сервера, номер - с сервера сразу на принтер.
void main() {
  const holder = BadgeHolder(
    id: 'u1',
    fullName: 'Иванов Иван',
    positionName: 'Кладовщик',
    isAdmin: false,
    stored: true,
  );
  late _MockRepo repo;
  late _MockPrinter printer;

  setUpAll(() => registerFallbackValue(_FakeLabel()));
  setUp(() {
    repo = _MockRepo();
    printer = _MockPrinter();
    when(() => repo.holders()).thenAnswer((_) async => const Right([holder]));
    when(() => repo.badge('u1')).thenAnswer(
      (_) async =>
          const Right((fullName: 'Иванов Иван', number: '1000000023456781')),
    );
  });

  test('список загружается; без связи - ошибка с причиной', () async {
    final c = BadgesCubit(repo, printer);
    await c.load();
    expect(c.state.status, BadgesStatus.loaded);
    expect(c.state.holders.single.id, 'u1');

    when(
      () => repo.holders(),
    ).thenAnswer((_) async => const Left(Failure.network()));
    await c.load();
    expect(c.state.status, BadgesStatus.error);
    expect(c.state.failure, isA<NetworkFailure>());
  });

  test('печать - номер с сервера в ярлык, подсказка «напечатан»', () async {
    when(() => printer.printBadgeLabel(any())).thenAnswer((_) async {});
    final c = BadgesCubit(repo, printer);
    await c.printBadge(holder, position: 'Должность: Кладовщик');
    final label =
        verify(() => printer.printBadgeLabel(captureAny())).captured.single
            as BadgeLabel;
    expect(label.number, '1000000023456781');
    expect(label.position, 'Должность: Кладовщик');
    expect(c.state.busy, isFalse);
    expect(c.state.notice, isA<BadgesNoticePrinted>());
  });

  test(
    'отказ сервера - без печати; отказ принтера - причина для человека',
    () async {
      when(() => repo.badge('u1')).thenAnswer(
        (_) async => const Left(Failure.server(409, 'номер не сохранён')),
      );
      final c = BadgesCubit(repo, printer);
      await c.printBadge(holder);
      verifyNever(() => printer.printBadgeLabel(any()));
      expect(c.state.notice, isA<BadgesNoticeFetchFailed>());

      when(() => repo.badge('u1')).thenAnswer(
        (_) async =>
            const Right((fullName: 'Иванов Иван', number: '1000000023456781')),
      );
      when(() => printer.printBadgeLabel(any())).thenThrow(
        const PrinterFailure(
          PrinterFailureKind.notSelected,
          'Принтер не выбран',
        ),
      );
      await c.printBadge(holder);
      expect(c.state.notice, isA<BadgesNoticePrintFailed>());
      expect(c.state.busy, isFalse);
    },
  );
}
