import '../../../../core/utils/doc_number.dart';
import '../../../../core/utils/search_text.dart';
import '../../../data/problems_repository.dart';
import 'problem_labels.dart';

/// Фильтр рабочего списка «Проблемы склада» (P6-07-3): открытые — то, что ждёт решения офиса.
enum ProblemFilter {
  open,
  resolved,
  all;

  /// Подходит ли проблема под фильтр.
  bool accepts(PortalProblem p) => switch (this) {
    ProblemFilter.open => !p.resolved,
    ProblemFilter.resolved => p.resolved,
    ProblemFilter.all => true,
  };
}

/// Счётчики фильтров — по всему списку, без учёта поиска.
Map<ProblemFilter, int> countProblems(List<PortalProblem> list) => {
  for (final f in ProblemFilter.values) f: list.where(f.accepts).length,
};

/// Проблемы под фильтр и поиск: все слова запроса — в номере, товаре, коде, ячейке, коробе,
/// причине, комментарии, складах, авторе или поставщике.
List<PortalProblem> applyProblemFilter(
  List<PortalProblem> list, {
  required ProblemFilter filter,
  required String query,
}) {
  final words = searchWords(query);
  return [
    for (final p in list)
      if (filter.accepts(p) &&
          words.every(normalizeSearchText(_searchText(p)).contains))
        p,
  ];
}

String _searchText(PortalProblem p) => [
  docNumber(DocKind.problem, p.number),
  p.cellAddress,
  p.loadUnitCode,
  reasonText(p),
  p.comment,
  p.mark,
  p.fromWarehouse,
  p.toWarehouse,
  p.createdBy,
  p.supplierName,
  p.docNumber,
  for (final it in p.items) ...[it.goodName, it.goodCode, it.cellAddress],
].join(' ');
