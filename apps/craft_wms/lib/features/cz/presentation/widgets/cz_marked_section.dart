import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/auth/auth_cubit.dart';
import '../../../../core/constants/app_boxes.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/error/failure.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/widgets/neumorphic_choice.dart';
import '../bloc/cz_marked_cubit.dart';
import 'cz_lines.dart';

/// Блок «Маркировка ЧЗ» в карточке товара (CZ-05): маркируемый ли товар.
///
/// Видят все — кладовщику признак объясняет, почему приёмка просит марку, а не ШК. Правит
/// только admin: признак ставится сам по факту, а правка исправляет ошибку (долг 16).
class CzMarkedSection extends StatelessWidget {
  const CzMarkedSection({
    super.key,
    required this.goodId,
    required this.marked,
  });

  /// Товар карточки.
  final String goodId;

  /// Признак по справочнику терминала.
  final bool marked;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) =>
          getIt<CzMarkedCubit>()..start(goodId: goodId, marked: marked),
      child: const _CzMarkedView(),
    );
  }
}

class _CzMarkedView extends StatelessWidget {
  const _CzMarkedView();

  /// Сохранить выбор admin.
  void select(BuildContext context, bool marked) =>
      context.read<CzMarkedCubit>().set(marked);

  /// Правка не сохранилась — сказать почему; признак на экране остался прежним.
  void onState(BuildContext context, CzMarkedState state) {
    final f = state.failure;
    if (f == null) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(failureText(f))));
  }

  /// Текст отказа: без связи — отдельно, отказ сервера — его словами.
  String failureText(Failure f) => switch (f) {
    NetworkFailure() => t.czMarked.offline,
    ServerFailure(:final message?) => t.czMarked.failed(reason: message),
    _ => t.czMarked.failedGeneric,
  };

  @override
  Widget build(BuildContext context) {
    // Без сессии в дереве (экраны вне входа, тесты) правки нет — только признак.
    final auth = context.read<AuthCubit?>()?.state;
    final isAdmin = auth is AuthAuthenticated && auth.profile.role == 'admin';
    return BlocConsumer<CzMarkedCubit, CzMarkedState>(
      listenWhen: (a, b) => b.failure != null && a.failure != b.failure,
      listener: onState,
      builder: (context, state) => czCard([
        czText(
          t.czMarked.line(value: state.marked ? t.czMarked.yes : t.czMarked.no),
        ),
        // Что значит признак для склада (CZ-06) и как быть с товаром, принятым без марок.
        if (state.marked) czText(t.czMarked.rule),
        if (isAdmin) ...[
          AppBoxes.kHeight8,
          Row(
            children: [
              NeumorphicChoice(
                label: t.czMarked.choiceMarked,
                selected: state.marked,
                onPressed: () => select(context, true),
              ),
              AppBoxes.kWidth8,
              NeumorphicChoice(
                label: t.czMarked.choiceUnmarked,
                selected: !state.marked,
                onPressed: () => select(context, false),
              ),
            ],
          ),
        ],
      ]),
    );
  }
}
