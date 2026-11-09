import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'auth_cubit.dart';
import 'rights.dart';

/// Права вошедшего для экранов (ADHOC-51): есть ли у должности хоть одно из прав
/// (`Profile.can`). Сессии в дереве нет (экран вне входа, тест) — [withoutSession].
bool sessionCan(
  BuildContext context,
  String right, {
  List<String> more = const [],
  bool withoutSession = false,
}) {
  final state = context.read<AuthCubit?>()?.state;
  if (state is! AuthAuthenticated) return withoutSession;
  return state.profile.can(right, more);
}

/// Права на виды заданий склада (ADHOC-51): размещение и возврат — «Задания: размещение и
/// возврат поставщику», пересчёт — считать ячейки или заводить и закрывать, возврат на места
/// после правки реестра (P9-07-1) — своё право.
List<String> taskKindRights(String kind) => switch (kind) {
  'stocktake' => const [Rights.tsdStocktakeCount, Rights.tsdStocktakeManage],
  'picking_return' => const [Rights.tsdPickingReturn],
  _ => const [Rights.tsdPutaway],
};
