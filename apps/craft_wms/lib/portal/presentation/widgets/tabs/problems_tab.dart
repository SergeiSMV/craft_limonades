import 'package:flutter/material.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/error/failure.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../data/problems_repository.dart';
import '../problems/problem_card.dart';
import '../problems/problem_filter.dart';
import '../problems/problem_resolve_dialog.dart';
import '../problems/problem_toolbar.dart';

/// Вкладка «Проблемы склада» (P6-07-3): рабочий список офиса. Склад помечает брак, просрок,
/// не нашу марку на ТСД; офис выбирает решение из допустимых при причине и проводит его —
/// списать по документу 1С, разместить в «Основной» или вернуть поставщику. Открытые сверху;
/// поиск и фильтр — по загруженному списку. Всё admin-only на бэке.
class ProblemsTab extends StatefulWidget {
  const ProblemsTab({super.key, this.canResolve = true});

  /// Право «Проблемы склада: принимать решение» (ADHOC-50); без него — только просмотр.
  final bool canResolve;

  @override
  State<ProblemsTab> createState() => _ProblemsTabState();
}

class _ProblemsTabState extends State<ProblemsTab> {
  final _repo = getIt<ProblemsRepository>();

  bool _loading = true;
  Failure? _error;
  List<PortalProblem> _problems = const [];
  final _posting = <String>{}; // id проблем, по которым идёт проведение решения

  ProblemFilter _filter = ProblemFilter.open;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Сменить фильтр.
  void _onFilter(ProblemFilter f) => setState(() => _filter = f);

  /// Запрос поиска изменился.
  void _onQuery(String q) => setState(() => _query = q);

  /// Загрузить список проблем.
  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final res = await _repo.list();
    if (!mounted) return;
    setState(() {
      _loading = false;
      res.fold((f) => _error = f, (list) => _problems = list);
    });
  }

  /// Решить проблему: решение собирается в диалоге и проводится сразу — остаток меняется
  /// только здесь. После успеха список перечитывается: решённая уходит из открытых.
  Future<void> _resolve(PortalProblem p) async {
    if (_posting.contains(p.id)) return;
    final resolution = await showProblemResolveDialog(context, p);
    if (resolution == null || !mounted) return;

    setState(() => _posting.add(p.id));
    final res = await _repo.resolve(p.id, resolution);
    if (!mounted) return;
    setState(() => _posting.remove(p.id));
    res.fold((f) => _snack(t.portal.problems.error(message: _errorText(f))), (
      _,
    ) {
      _snack(t.portal.problems.posted);
      _load();
    });
  }

  /// Текст ошибки: отказ по существу сервер объясняет сам.
  String _errorText(Failure f) => switch (f) {
    ServerFailure(:final message, :final statusCode) =>
      message ?? 'HTTP $statusCode',
    NetworkFailure() => t.portal.login.errorNetwork,
    _ => t.portal.login.errorUnknown,
  };

  /// Показать снекбар.
  void _snack(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    // Как у документов: панель поиска и фильтров закреплена, прокручивается только список.
    final compact =
        MediaQuery.sizeOf(context).width < AppSizes.kPortalCompactContentWidth;
    final pad = compact ? AppInsets.all16 : AppInsets.all32;
    final state = _state();
    if (state != null) {
      return SingleChildScrollView(padding: pad, child: _column(state));
    }
    final shown = applyProblemFilter(_problems, filter: _filter, query: _query);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: pad.copyWith(bottom: 0),
          child: _column(
            ProblemToolbar(
              onQuery: _onQuery,
              filter: _filter,
              counts: countProblems(_problems),
              onFilter: _onFilter,
            ),
          ),
        ),
        AppBoxes.kHeight8,
        Expanded(
          child: ListView.separated(
            padding: pad.copyWith(top: AppSizes.kDocListGap),
            itemCount: shown.isEmpty ? 1 : shown.length,
            separatorBuilder: (_, _) => AppBoxes.kHeight16,
            itemBuilder: (_, i) => _column(
              shown.isEmpty
                  ? _message(t.portal.problems.notFound)
                  : ProblemCard(
                      problem: shown[i],
                      busy: _posting.contains(shown[i].id),
                      onResolve: widget.canResolve
                          ? () => _resolve(shown[i])
                          : null,
                    ),
            ),
          ),
        ),
      ],
    );
  }

  /// Колонка вкладки: прижата влево, не шире таблицы документов.
  Widget _column(Widget child) => Align(
    alignment: Alignment.topLeft,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: AppSizes.kDocTableMaxWidth),
      child: SizedBox(width: double.infinity, child: child),
    ),
  );

  Widget _message(String text) => Padding(
    padding: AppInsets.all32,
    child: Center(
      child: Text(
        text,
        style: RegularTextStyles().regularInter14.copyWith(
          color: AppColors.kTextMuted,
        ),
      ),
    ),
  );

  /// Состояние вместо списка: загрузка / ошибка / пусто; `null` — есть проблемы.
  Widget? _state() {
    if (_loading) {
      return const Padding(
        padding: AppInsets.all32,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_error != null) {
      return Column(
        children: [
          Text(
            t.portal.problems.error(message: _errorText(_error!)),
            style: RegularTextStyles().regularInter14.copyWith(
              color: AppColors.kDanger,
            ),
          ),
          AppBoxes.kHeight16,
          OutlinedButton(
            onPressed: _load,
            child: Text(t.portal.problems.retry),
          ),
        ],
      );
    }
    if (_problems.isEmpty) return _message(t.portal.problems.empty);
    return null;
  }
}
