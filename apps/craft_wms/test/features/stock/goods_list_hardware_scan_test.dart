import 'package:craft_wms/core/di/injection.dart';
import 'package:craft_wms/core/error/failure.dart';
import 'package:craft_wms/core/gen/strings.g.dart';
import 'package:craft_wms/core/theme/app_theme.dart';
import 'package:craft_wms/features/stock/data/catalog_models.dart';
import 'package:craft_wms/features/stock/data/catalog_repository.dart';
import 'package:craft_wms/features/stock/presentation/bloc/goods_list_cubit.dart';
import 'package:craft_wms/features/stock/presentation/pages/goods_list_page.dart';
import 'package:either_dart/either.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../support/fake_scanner_service.dart';

class _MockRepo extends Mock implements CatalogRepository {}

/// «Остатки»: код с аппаратного сканера идёт тем же путём, что и завершённый ввод в строке поиска.
/// Экран не должен зависеть от того, каким режимом сканера настроено устройство.
void main() {
  late _MockRepo repo;

  setUp(() {
    LocaleSettings.useDeviceLocale();
    repo = _MockRepo();
    when(
      () => repo.listGroups(),
    ).thenAnswer((_) async => const Right(<NomenclatureGroup>[]));
    when(
      () => repo.listSuppliers(),
    ).thenAnswer((_) async => const Right(<Supplier>[]));
    when(
      () => repo.listGoods(
        query: any(named: 'query'),
        groupId: any(named: 'groupId'),
        supplierId: any(named: 'supplierId'),
        limit: any(named: 'limit'),
        offset: any(named: 'offset'),
      ),
    ).thenAnswer(
      (_) async => const Right(
        Paged<Good>(items: <Good>[], total: 0, limit: 50, offset: 0),
      ),
    );
    if (getIt.isRegistered<GoodsListCubit>()) {
      getIt.unregister<GoodsListCubit>();
    }
    getIt.registerFactory<GoodsListCubit>(() => GoodsListCubit(repo));
  });

  Widget wrap() =>
      MaterialApp(theme: buildAppTheme(), home: const GoodsListPage());

  testWidgets('скан из потока резолвится как штрихкод, а не ищется по имени', (
    tester,
  ) async {
    final scanner = registerFakeScanner();
    when(
      () => repo.resolveGoodByBarcode('4607091380001'),
    ).thenAnswer((_) async => const Right<Failure, Good?>(null));

    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    scanner.emit('4607091380001');
    await tester.pumpAndSettle();

    verify(() => repo.resolveGoodByBarcode('4607091380001')).called(1);
    expect(
      find.text(t.stockListScreen.barcodeNotFound(barcode: '4607091380001')),
      findsOneWidget,
    );
    await scanner.dispose();
  });
}
