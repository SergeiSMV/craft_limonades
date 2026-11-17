import 'package:flutter/material.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/error/failure.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/sync/data_versions.dart';
import '../../../../core/widgets/data_versions_listener.dart';
import '../../../domain/problems/problems_repository.dart';
import '../problems/problem_card.dart';
import '../problems/problem_filter.dart';
import '../problems/problem_resolve_dialog.dart';
import '../problems/problem_toolbar.dart';
import '../settings/access_common.dart';
import '../ui/portal_button.dart';
import '../ui/portal_card.dart';
import '../ui/portal_list_page.dart';

/// Вкладка «Проблемы склада» (P6-07-3): рабочий список офиса. Склад помечает брак, просрок,
/// не нашу марку на ТСД; офис выбирает решение из допустимых при причине и проводит его -
/// списать по документу 1С, разместить в «Основной» или вернуть поставщику. Открытые сверху;
/// поиск и фильтр - по загруженному списку. Всё admin-only на бэке.
class ProblemsTab extends StatefulWidget {
  const ProblemsTab({super.key, this.canResolve = true});

  /// Право «Проблемы склада: принимать решение» (ADHOC-50); без него - только просмотр.
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

  /// Загрузить список проблем. [quiet] - перечитывание по версиям данных (ADHOC-60): список
  /// остаётся на экране до ответа, а ошибка не подменяет его.
  Future<void> _load({bool quiet = false}) async {
    if (!quiet) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    final res = await _repo.list();
    if (!mounted || (quiet && res.isLeft)) return;
    setState(() {
      _loading = false;
      res.fold((f) => _error = f, (list) {
        _problems = list;
        _error = null;
      });
    });
  }

  /// Проблемы изменились на сервере (ADHOC-60): тихо перечитать; поиск и фильтр не трогаются.
  void _onDataChanged() => _load(quiet: true);

  /// Решить проблему: решение собирается в диалоге и проводится сразу - остаток меняется
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
    // Как у документов (ADHOC-56): панель поиска и фильтров закреплена, прокручивается только
    // список; ширина и поля - как у остальных страниц-списков.
    return DataVersionsListener(
      domains: const {DataDomain.problems},
      onChanged: _onDataChanged,
      child: PortalListPage(
        toolbar: ProblemToolbar(
          onQuery: _onQuery,
          filter: _filter,
          counts: countProblems(_problems),
          onFilter: _onFilter,
        ),
        body: _body(),
      ),
    );
  }

  /// Проблемы карточками друг под другом; вместо них - загрузка / ошибка / пусто.
  Widget _body() {
    if (_loading) {
      return const SettingsListCard(loading: true, rows: []);
    }
    final error = _error;
    if (error != null) {
      return PortalCard(
        children: [
          Padding(
            padding: AppInsets.cardRow,
            child: Row(
              children: [
                Expanded(
                  child: AccessError(
                    t.portal.problems.error(message: _errorText(error)),
                  ),
                ),
                AppBoxes.kWidth8,
                PortalButton(label: t.portal.problems.retry, onPressed: _load),
              ],
            ),
          ),
        ],
      );
    }
    final shown = applyProblemFilter(_problems, filter: _filter, query: _query);
    if (shown.isEmpty) {
      return _message(
        _problems.isEmpty
            ? t.portal.problems.empty
            : t.portal.problems.notFound,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < shown.length; i++) ...[
          if (i > 0) AppBoxes.kHeight12,
          ProblemCard(
            problem: shown[i],
            busy: _posting.contains(shown[i].id),
            onResolve: widget.canResolve ? () => _resolve(shown[i]) : null,
          ),
        ],
      ],
    );
  }

  /// Сообщение вместо списка - карточкой под панелью.
  Widget _message(String text) => PortalCard(
    children: [
      Padding(
        padding: AppInsets.cardRow,
        child: Text(
          text,
          style: RegularTextStyles().regularInter13.copyWith(
            color: AppColors.kTextMuted,
          ),
        ),
      ),
    ],
  );
}
