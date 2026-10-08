import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/gen/assets.gen.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/widgets/page_header.dart';
import '../../../../core/widgets/tab_switch.dart';
import '../../../../core/widgets/system_ui_wrapper.dart';
import '../bloc/completed_tasks_cubit.dart';
import '../bloc/current_tasks_cubit.dart';
import '../widgets/common/tasks_filter_button.dart';
import '../widgets/completed/completed_feed.dart';
import '../widgets/current/current_tasks_view.dart';

/// Раздел «ЗАДАНИЯ» (P5-02-1): вкладки «Текущие» и «Завершённые».
///
/// Шапка — как у «Приёмки»: фон-картинка, заголовок с возвратом и фильтр выбранной вкладки.
/// Переключатель вкладок закреплён в теле над списком и не уезжает при прокрутке.
/// «Текущие» грузятся сразу и работают без связи (снимок на терминале); «Завершённые» —
/// только онлайн и грузятся при первом открытии вкладки, а не вместе с разделом.
@RoutePage()
class TasksPage extends StatelessWidget {
  const TasksPage({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider(create: (_) => getIt<CurrentTasksCubit>()..load()),
        BlocProvider(create: (_) => getIt<CompletedTasksCubit>()),
      ],
      child: const _TasksView(),
    );
  }
}

class _TasksView extends StatefulWidget {
  const _TasksView();

  @override
  State<_TasksView> createState() => _TasksViewState();
}

class _TasksViewState extends State<_TasksView> {
  int _tab = 0;

  /// Переключить вкладку; ленту грузим при первом заходе в «Завершённые».
  void selectTab(int index) {
    setState(() => _tab = index);
    final completed = context.read<CompletedTasksCubit>();
    if (index == 1 && completed.state.status == CompletedStatus.initial) {
      completed.load();
    }
  }

  /// Вернуться на главный экран.
  void goBack() => context.router.maybePop();

  @override
  Widget build(BuildContext context) {
    return SystemUiWrapper(
      style: StatusBarStyle.light,
      child: Scaffold(
        backgroundColor: AppColors.kNeumorphicBg,
        appBar: AppBar(
          automaticallyImplyLeading: false,
          backgroundColor: Colors.transparent,
          elevation: 0,
          toolbarHeight: AppSizes.kIcon60,
          flexibleSpace: ClipRRect(
            borderRadius: AppBorders.kBottom10,
            child: Assets.images.featuredSnacks.image(fit: BoxFit.cover),
          ),
          title: PageHeader(
            title: t.tasks.title,
            goBack: goBack,
            trailing: TasksFilterButton(completedTab: _tab == 1),
          ),
        ),
        body: Column(
          children: [
            Padding(
              padding: AppInsets.h8 + AppInsets.v16,
              child: TabSwitch(
                labels: [t.tasks.tabCurrent, t.tasks.tabCompleted],
                selected: _tab,
                onSelected: selectTab,
                activeColor: AppColors.kTileTasks,
              ),
            ),
            Expanded(
              child: IndexedStack(
                index: _tab,
                children: const [CurrentTasksView(), CompletedFeed()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
