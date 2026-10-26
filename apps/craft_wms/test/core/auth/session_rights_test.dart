import 'package:craft_wms/core/auth/auth_cubit.dart';
import 'package:craft_wms/core/auth/profile.dart';
import 'package:craft_wms/core/auth/rights.dart';
import 'package:craft_wms/core/auth/session_rights.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockAuth extends Mock implements AuthCubit {}

/// ADHOC-51: права вошедшего для экранов ТСД и права на виды заданий.
void main() {
  Future<bool Function(String, {List<String> more, bool withoutSession})> pump(
    WidgetTester tester,
    AuthCubit? auth,
  ) async {
    late BuildContext ctx;
    final child = Builder(
      builder: (context) {
        ctx = context;
        return const SizedBox();
      },
    );
    await tester.pumpWidget(
      auth == null
          ? MaterialApp(home: child)
          : MaterialApp(
              home: BlocProvider<AuthCubit>.value(value: auth, child: child),
            ),
    );
    return (
      String right, {
      List<String> more = const <String>[],
      bool withoutSession = false,
    }) => sessionCan(ctx, right, more: more, withoutSession: withoutSession);
  }

  _MockAuth authWith(List<String> rights) {
    final auth = _MockAuth();
    final state = AuthState.authenticated(
      Profile(
        userId: 'u1',
        login: '',
        fullName: 'Приёмщик',
        role: 'employee',
        position: 'Приёмщик',
        rights: rights,
      ),
    );
    when(() => auth.state).thenReturn(state);
    when(() => auth.stream).thenAnswer((_) => const Stream.empty());
    return auth;
  }

  testWidgets('права должности; без сессии — значение по умолчанию', (
    tester,
  ) async {
    var can = await pump(tester, authWith([Rights.tsdReceipt]));
    expect(can(Rights.tsdReceipt), isTrue);
    expect(can(Rights.tsdMovement), isFalse);
    expect(can(Rights.tsdMovement, more: [Rights.tsdReceipt]), isTrue);
    expect(can(Rights.tsd), isTrue);

    can = await pump(tester, null);
    expect(can(Rights.tsdReceipt), isFalse);
    expect(can(Rights.tsdReceipt, withoutSession: true), isTrue);
  });

  test(
    'виды заданий: пересчёт — считать или заводить, остальное — размещение',
    () {
      expect(taskKindRights('stocktake'), [
        Rights.tsdStocktakeCount,
        Rights.tsdStocktakeManage,
      ]);
      expect(taskKindRights('putaway'), [Rights.tsdPutaway]);
      expect(taskKindRights('supplier_return'), [Rights.tsdPutaway]);
    },
  );
}
