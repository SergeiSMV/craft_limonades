import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import '../../../../../core/constants/app_colors.dart';
import '../../../../../core/constants/app_sizes.dart';
import '../../../../tasks/presentation/widgets/common/tasks_filter_sheet.dart';
import '../../bloc/resolved_problems_cubit.dart';

/// Кнопка фильтра ленты «Завершённые» проблем в шапке раздела, с бейджем числа условий.
/// Лист - общий с заданиями и перемещениями, только период: по исполнителю и виду лента
/// решённых проблем не фильтруется.
class ResolvedFilterButton extends StatelessWidget {
  const ResolvedFilterButton({super.key});

  /// Открыть фильтр и применить выбранное - лента перезагружается отдельным запросом.
  Future<void> openFilter(BuildContext context) async {
    final cubit = context.read<ResolvedProblemsCubit>();
    final picked = await showTasksFilterSheet(
      context,
      current: cubit.state.filter,
      showKind: false,
      showExecutor: false,
    );
    if (picked != null) await cubit.setFilter(picked);
  }

  @override
  Widget build(BuildContext context) {
    final count = context.select(
      (ResolvedProblemsCubit c) => c.state.filter.activeCount,
    );
    return IconButton(
      onPressed: () => openFilter(context),
      icon: Badge.count(
        count: count,
        isLabelVisible: count > 0,
        child: Icon(
          MdiIcons.filterVariant,
          size: AppSizes.kIcon25,
          color: AppColors.kNeumorphicBg,
        ),
      ),
    );
  }
}
