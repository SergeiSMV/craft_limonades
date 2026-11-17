import 'catalog_models.dart';

/// Идентификаторы группы [rootId] и всех её потомков.
///
/// Зачем: выбор родительской группы должен показывать товары из вложенных, иначе фильтр по
/// верхнему уровню даёт пусто. На сервере это рекурсивный CTE (P1-07), здесь - обход дерева
/// в памяти: групп немного, и грузятся они всё равно целиком.
///
/// Лежит в `domain`, а не в кэше справочников (ADHOC-71): правило дерева нужно и кэшу, и
/// фильтрам экранов ТСД и портала, а им ходить в `data/` нельзя.
List<String> descendantGroupIds(List<NomenclatureGroup> all, String rootId) {
  final children = <String, List<String>>{};
  for (final g in all) {
    final parent = g.parentId;
    if (parent != null) (children[parent] ??= []).add(g.id);
  }
  final result = <String>[rootId];
  final queue = <String>[rootId];
  while (queue.isNotEmpty) {
    final next = children[queue.removeLast()] ?? const [];
    result.addAll(next);
    queue.addAll(next);
  }
  return result;
}
