import 'package:auto_route/auto_route.dart';
import 'package:flutter/widgets.dart';

import '../../../core/di/injection.dart';
import '../../../core/router/app_router.dart';
import '../data/catalog_models.dart';
import '../data/catalog_repository.dart';

/// Открыть карточку остатков товара по идентификатору — из другого раздела (P5-05-1: строка
/// содержимого короба).
///
/// Карточка ждёт товар целиком (группа, поставщик — в шапке), а строка содержимого знает только
/// идентификатор и наименование. Товар берётся из справочника терминала; нет его там (заведён
/// после загрузки) — карточка открывается с тем, что известно: остатки и штрихкоды она всё
/// равно читает по идентификатору.
Future<void> openGoodCard(
  BuildContext context, {
  required String goodId,
  required String name,
  String? code,
  String? uom,
}) async {
  final router = context.router;
  final good =
      await getIt<CatalogRepository>().goodById(goodId) ??
      Good(id: goodId, name: name, code: code, uom: uom ?? '');
  await router.push(StockDetailRoute(good: good));
}
