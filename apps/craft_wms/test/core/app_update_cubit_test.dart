import 'dart:async';

import 'package:craft_wms/core/app_update/app_update_cubit.dart';
import 'package:craft_wms/core/app_update/app_update_service.dart';
import 'package:craft_wms/core/outbox/outbox_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:talker_flutter/talker_flutter.dart';

class _MockService extends Mock implements AppUpdateService {}

class _MockOutbox extends Mock implements OutboxRepository {}

/// Обновление приложения (ADHOC-69): отказ магазина молчит, кнопка появляется только у
/// скачанной версии, установка - только при пустой очереди, магазин - не чаще интервала.
void main() {
  late _MockService service;
  late _MockOutbox outbox;
  late StreamController<AppUpdateDownloadEvent> downloads;
  late AppUpdateCubit cubit;

  setUp(() {
    service = _MockService();
    outbox = _MockOutbox();
    downloads = StreamController<AppUpdateDownloadEvent>.broadcast();
    when(() => service.supported).thenReturn(true);
    when(() => service.downloadEvents).thenAnswer((_) => downloads.stream);
    when(() => service.startDownload()).thenAnswer((_) async {});
    when(() => service.install()).thenAnswer((_) async {});
    cubit = AppUpdateCubit(
      service,
      outbox,
      Talker(settings: TalkerSettings(enabled: false)),
    );
  });

  tearDown(() async {
    await cubit.close();
    await downloads.close();
  });

  test('стенд и демо: магазин не опрашивается', () async {
    when(() => service.supported).thenReturn(false);
    await cubit.check();
    verifyNever(() => service.check());
    expect(cubit.state, AppUpdateState.hidden);
  });

  test('нет входа в RuStore: без ошибки, кнопки нет', () async {
    when(
      () => service.check(),
    ).thenThrow(const AppUpdateUnavailable('RuStoreUserUnauthorizedException'));
    await cubit.check();
    expect(cubit.state, AppUpdateState.hidden);
    verifyNever(() => service.startDownload());
  });

  test('обновления нет: скачивание не запускается', () async {
    when(
      () => service.check(),
    ).thenAnswer((_) async => AppUpdateAvailability.none);
    await cubit.check();
    verifyNever(() => service.startDownload());
    expect(cubit.state, AppUpdateState.hidden);
  });

  test('уже скачано: кнопка сразу', () async {
    when(
      () => service.check(),
    ).thenAnswer((_) async => AppUpdateAvailability.downloaded);
    await cubit.check();
    expect(cubit.state, AppUpdateState.ready);
  });

  test('есть версия: тихое скачивание, кнопка после «скачано»', () async {
    when(
      () => service.check(),
    ).thenAnswer((_) async => AppUpdateAvailability.available);
    await cubit.check();
    verify(() => service.startDownload()).called(1);
    expect(cubit.state, AppUpdateState.hidden);

    downloads.add(AppUpdateDownloadEvent.downloading);
    await pumpEventQueue();
    expect(cubit.state, AppUpdateState.hidden);

    downloads.add(AppUpdateDownloadEvent.downloaded);
    await pumpEventQueue();
    expect(cubit.state, AppUpdateState.ready);
  });

  test('ошибка скачивания: кнопки нет', () async {
    when(
      () => service.check(),
    ).thenAnswer((_) async => AppUpdateAvailability.available);
    await cubit.check();
    downloads.add(AppUpdateDownloadEvent.failed);
    await pumpEventQueue();
    expect(cubit.state, AppUpdateState.hidden);
  });

  test('очередь не пуста: установка не запускается', () async {
    when(() => outbox.pendingCount()).thenAnswer((_) async => 3);
    final result = await cubit.install();
    expect(result, AppUpdateInstallResult.queueNotEmpty);
    verifyNever(() => service.install());
  });

  test('очередь пуста: установка запускается', () async {
    when(() => outbox.pendingCount()).thenAnswer((_) async => 0);
    final result = await cubit.install();
    expect(result, AppUpdateInstallResult.started);
    verify(() => service.install()).called(1);
    expect(cubit.state, AppUpdateState.installing);
  });

  test('отказ установки: снова кнопка', () async {
    when(() => outbox.pendingCount()).thenAnswer((_) async => 0);
    when(() => service.install()).thenThrow(const AppUpdateUnavailable('4010'));
    final result = await cubit.install();
    expect(result, AppUpdateInstallResult.failed);
    expect(cubit.state, AppUpdateState.ready);
  });

  test('повторная проверка раньше интервала магазин не спрашивает', () async {
    when(
      () => service.check(),
    ).thenAnswer((_) async => AppUpdateAvailability.none);
    final t0 = DateTime(2026, 11, 10, 8);
    await cubit.check(now: t0);
    await cubit.check(now: t0.add(const Duration(hours: 1)));
    verify(() => service.check()).called(1);
    await cubit.check(now: t0.add(AppUpdateCubit.checkInterval));
    verify(() => service.check()).called(1);
  });

  test('отказ магазина: повтор - через интервал', () async {
    when(
      () => service.check(),
    ).thenThrow(const AppUpdateUnavailable('RuStoreException 404'));
    final t0 = DateTime(2026, 11, 10, 8);
    await cubit.check(now: t0);
    await cubit.check(now: t0.add(const Duration(minutes: 5)));
    await cubit.check(now: t0.add(AppUpdateCubit.checkInterval));
    verify(() => service.check()).called(2);
  });

  test('идёт скачивание: магазин не спрашивается заново', () async {
    when(
      () => service.check(),
    ).thenAnswer((_) async => AppUpdateAvailability.available);
    final t0 = DateTime(2026, 11, 10, 8);
    await cubit.check(now: t0);
    await cubit.check(now: t0.add(const Duration(hours: 5)));
    verify(() => service.check()).called(1);
  });

  test('ошибка скачивания: следующая проверка качает заново', () async {
    when(
      () => service.check(),
    ).thenAnswer((_) async => AppUpdateAvailability.available);
    final t0 = DateTime(2026, 11, 10, 8);
    await cubit.check(now: t0);
    downloads.add(AppUpdateDownloadEvent.failed);
    await pumpEventQueue();
    await cubit.check(now: t0.add(AppUpdateCubit.checkInterval));
    verify(() => service.startDownload()).called(2);
  });

  test('уже скачано: проверка больше не нужна', () async {
    when(
      () => service.check(),
    ).thenAnswer((_) async => AppUpdateAvailability.downloaded);
    final t0 = DateTime(2026, 11, 10, 8);
    await cubit.check(now: t0);
    await cubit.check(now: t0.add(const Duration(hours: 5)));
    verify(() => service.check()).called(1);
    expect(cubit.state, AppUpdateState.ready);
  });
}
