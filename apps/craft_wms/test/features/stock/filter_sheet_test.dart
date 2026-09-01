import 'package:craft_wms/core/gen/strings.g.dart';
import 'package:craft_wms/features/stock/data/catalog_models.dart';
import 'package:craft_wms/features/stock/data/catalog_repository.dart';
import 'package:craft_wms/features/stock/presentation/bloc/goods_list_cubit.dart';
import 'package:craft_wms/features/stock/presentation/widgets/goods_list/stock_filter_button.dart';
import 'package:either_dart/either.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart'
    show NeumorphicButton;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockRepo extends Mock implements CatalogRepository {}

/// Длинное имя группы — не влезает в одну строку на ширине экрана ТСД.
const _longGroup =
    'Снеки орехово-фруктовые в потребительской упаковке (сегмент HoReCa)';

void main() {
  /// Поднять экран с кнопкой фильтров и открыть нижний лист.
  Future<GoodsListCubit> pumpSheet(WidgetTester tester) async {
    LocaleSettings.useDeviceLocale();
    final repo = _MockRepo();
    when(() => repo.listGroups()).thenAnswer(
      (_) async => const Right([
        NomenclatureGroup(id: 'g1', code: '1', name: 'ОРЕХИ И СЕМЕЧКИ'),
        NomenclatureGroup(id: 'g2', code: '2', name: _longGroup),
      ]),
    );
    when(() => repo.listSuppliers()).thenAnswer(
      (_) async => const Right([Supplier(id: 's1', name: 'ООО «ТОРГМАРКЕТ»')]),
    );
    when(
      () => repo.listGoods(
        query: any(named: 'query'),
        groupId: any(named: 'groupId'),
        supplierId: any(named: 'supplierId'),
        limit: any(named: 'limit'),
        offset: any(named: 'offset'),
      ),
    ).thenAnswer(
      (_) async =>
          Right(Paged<Good>(items: const [], total: 0, limit: 50, offset: 0)),
    );

    final cubit = GoodsListCubit(repo);
    await cubit.init();

    await tester.pumpWidget(
      BlocProvider.value(
        value: cubit,
        child: const MaterialApp(
          home: Scaffold(body: Center(child: FilterButton())),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(FilterButton));
    await tester.pumpAndSettle();
    return cubit;
  }

  /// Открыть меню фильтра по группе (первый дропдаун листа).
  Future<void> openGroupMenu(WidgetTester tester) async {
    await tester.tap(find.byType(DropdownButtonFormField<String?>).first);
    await tester.pumpAndSettle();
  }

  testWidgets('варианты меню — неоморфные кнопки', (tester) async {
    await pumpSheet(tester);
    await openGroupMenu(tester);

    // 3 варианта («Все» + 2 группы) + сама кнопка фильтров под листом.
    expect(find.byType(NeumorphicButton), findsNWidgets(4));
  });

  testWidgets('длинное название переносится, а не обрезается', (tester) async {
    await pumpSheet(tester);
    await openGroupMenu(tester);

    expect(find.text(_longGroup), findsOneWidget);
    final oneLine = tester.getSize(find.text('ОРЕХИ И СЕМЕЧКИ')).height;
    expect(
      tester.getSize(find.text(_longGroup)).height,
      greaterThan(oneLine * 1.5),
      reason: 'название должно занимать больше одной строки',
    );
  });

  testWidgets('тап по варианту применяет фильтр и закрывает только меню', (
    tester,
  ) async {
    // Тап перехватывает NeumorphicButton, а не DropdownMenuItem, поэтому выбор и закрытие
    // меню делает сама кнопка — регрессия здесь тихая (закрылся бы весь лист).
    final cubit = await pumpSheet(tester);
    await openGroupMenu(tester);

    await tester.tap(find.text(_longGroup));
    await tester.pumpAndSettle();

    expect(cubit.state.groupId, 'g2');
    expect(find.text(t.stockListScreen.filtersTitle), findsOneWidget);
  });

  testWidgets('выбранный вариант помечен точкой, остальные — нет', (
    tester,
  ) async {
    final cubit = await pumpSheet(tester);
    await cubit.setGroup('g2');
    await tester.pumpAndSettle();
    await openGroupMenu(tester);

    // Отметка ровно одна — у выбранного варианта.
    expect(find.byKey(const Key('filter-selected-dot')), findsOneWidget);
  });
}
