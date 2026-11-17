import '../../../data/documents_repository.dart';

/// Фильтр списка документов по состоянию в 1С (ADHOC-26).
///
/// Оператору важно одно: занесён документ в 1С или ещё ждёт. «Новый» и «скачан» для него -
/// одно состояние «ожидает»: скачанный, но не проведённый документ работы всё ещё требует.
enum DocFilter {
  all,
  waiting,
  posted;

  /// Подходит ли документ под фильтр.
  bool accepts(PortalDoc doc) => switch (this) {
    DocFilter.all => true,
    DocFilter.waiting => !isPosted(doc),
    DocFilter.posted => isPosted(doc),
  };
}

/// Документ проведён в 1С - оператор отметил его выполненным.
bool isPosted(PortalDoc doc) => doc.status == DocStatus.done;

/// Число документов под каждым фильтром - для счётчиков на чипах. Считается по всему списку,
/// без учёта поиска: счётчик отвечает «сколько всего ждёт», а не «сколько нашлось».
Map<DocFilter, int> countByFilter(List<PortalDoc> docs) => {
  for (final f in DocFilter.values) f: docs.where(f.accepts).length,
};

/// Документы под фильтром и поиском, в порядке сервера (ожидающие сверху, свежие первыми).
///
/// Поиск - без учёта регистра по тексту, который даёт [searchText]: у каждой формы свои
/// поля (поставщик и накладная, задание, дата). Пустой запрос ничего не отсекает.
List<PortalDoc> applyFilter(
  List<PortalDoc> docs, {
  required DocFilter filter,
  required String query,
  required String Function(PortalDoc) searchText,
}) {
  final q = query.trim().toLowerCase();
  return [
    for (final d in docs)
      if (filter.accepts(d) &&
          (q.isEmpty || searchText(d).toLowerCase().contains(q)))
        d,
  ];
}
