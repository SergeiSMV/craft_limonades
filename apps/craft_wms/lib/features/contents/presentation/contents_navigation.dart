import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';

import '../../../core/di/injection.dart';
import '../../../core/gen/strings.g.dart';
import '../../../core/router/app_router.dart';
import '../../../core/scanner/scan_code.dart';
import '../domain/contents_entities.dart';
import '../domain/contents_repository.dart';

/// Открыть по скану ячейку или короб (P5-05).
///
/// Что: QR короба — карточка короба, этикетка ячейки — её содержимое.
/// Зачем отдельной функцией: сканируют из «Остатков» и с самих экранов содержимого (из ячейки
/// в короб, из короба в соседнюю ячейку), и правило «что открыть» должно быть одно.
/// Как: возвращает `false`, если код не ячейки и не короба, — его обработает вызывающий
/// (в «Остатках» это поиск товара). [replace] — заменить текущий экран, а не положить сверху:
/// скан с экрана содержимого не должен копить стопку экранов. [unknownCellIsMine] — `false`:
/// похожий на адрес код, которого нет в справочнике ячеек, отдать вызывающему, а не отвечать
/// «нет такой ячейки» (в «Остатках» по такому тексту ищут товар).
Future<bool> openScannedContents(
  BuildContext context,
  ScanCode code, {
  bool replace = false,
  bool unknownCellIsMine = true,
}) async {
  // Роутер и мессенджер берутся только в своих ветках: код товара сюда тоже приходит,
  // и требовать для него навигацию незачем.
  switch (code.kind) {
    case ScanKind.cargoUnit:
      final router = context.router;
      final route = LoadUnitRoute(loadUnitId: code.loadUnitId!);
      // Не ждём: push завершается, только когда экран закроют.
      unawaited(replace ? router.replace(route) : router.push(route));
      return true;
    case ScanKind.cell:
      final CellRef? cell = await getIt<ContentsRepository>().findCell(
        code.raw,
      );
      if (cell == null && !unknownCellIsMine) return false;
      // Экран могли закрыть, пока искали ячейку, — тогда скан уже некому показывать.
      if (!context.mounted) return true;
      final router = context.router;
      final messenger = ScaffoldMessenger.of(context);
      if (cell == null) {
        messenger.showSnackBar(
          SnackBar(content: Text(t.contents.cellNotFound(address: code.raw))),
        );
        return true;
      }
      final route = CellContentsRoute(cellId: cell.id, address: cell.address);
      unawaited(replace ? router.replace(route) : router.push(route));
      return true;
    case ScanKind.good:
    case ScanKind.unknown:
      return false;
  }
}
