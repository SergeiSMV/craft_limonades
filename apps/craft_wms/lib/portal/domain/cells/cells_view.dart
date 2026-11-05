import 'cell_setup.dart';

/// Быстрый фильтр по балке над списком.
enum BeamFilter { all, large, small }

/// Фильтр «Признак» панели.
enum FlagFilter { floor, barcode, noBarcode, sideCard }

/// Фильтры списка ячеек: поиск по адресу, стеллаж, признак и балка.
class CellsFilter {
  const CellsFilter({
    this.query = '',
    this.rackId,
    this.flag,
    this.beam = BeamFilter.all,
  });

  final String query;
  final String? rackId;
  final FlagFilter? flag;
  final BeamFilter beam;

  CellsFilter copyWith({
    String? query,
    String? Function()? rackId,
    FlagFilter? Function()? flag,
    BeamFilter? beam,
  }) => CellsFilter(
    query: query ?? this.query,
    rackId: rackId != null ? rackId() : this.rackId,
    flag: flag != null ? flag() : this.flag,
    beam: beam ?? this.beam,
  );
}

/// Ячейки и стеллажи страницы с расчётами, которые не зависят от вёрстки: порядок, фильтры,
/// сводные галочки выборки и счётчики печати.
class CellsView {
  CellsView(CellsSetup setup)
    : warehouse = setup.warehouse,
      racks = [...setup.racks]..sort((a, b) => naturalCompare(a.code, b.code)),
      cells = [...setup.cells]..sort(_stickOrder);

  final String warehouse;
  final List<Rack> racks;

  /// Ячейки в порядке наклейки: по стеллажу (без стеллажа — в конце), по позиции слева
  /// направо, в позиции — ярусы сверху вниз. Так же печатает бэкенд.
  final List<CellSetup> cells;

  /// Ячейки под фильтр; [ignoreBeam] — без фильтра по балке (для счётчиков быстрых фильтров).
  List<CellSetup> filtered(CellsFilter f, {bool ignoreBeam = false}) {
    final q = f.query.trim().toUpperCase();
    return [
      for (final c in cells)
        if ((q.isEmpty || c.address.toUpperCase().contains(q)) &&
            (f.rackId == null || c.rackId == f.rackId) &&
            _flag(c, f.flag) &&
            (ignoreBeam || _beam(c, f.beam)))
          c,
    ];
  }

  bool _flag(CellSetup c, FlagFilter? f) => switch (f) {
    null => true,
    FlagFilter.floor => c.isFloor,
    FlagFilter.barcode => c.labelBarcode,
    FlagFilter.noBarcode => !c.labelBarcode,
    FlagFilter.sideCard => c.sideCard,
  };

  static bool _beam(CellSetup c, BeamFilter b) => switch (b) {
    BeamFilter.all => true,
    BeamFilter.large => !c.labelSmall,
    BeamFilter.small => c.labelSmall,
  };

  /// Сводная галочка выборки: у всех — `true`, ни у кого — `false`, у части — `null`.
  /// «На карточке» считается только по ячейкам со стеллажом: у остальных её не бывает.
  bool? aggregate(List<CellSetup> list, CellFlag flag) {
    final of = flag == CellFlag.sideCard
        ? list.where((c) => c.rackId != null).toList()
        : list;
    final on = of
        .where(
          (c) => switch (flag) {
            CellFlag.small => c.labelSmall,
            CellFlag.floor => c.isFloor,
            CellFlag.barcode => c.labelBarcode,
            CellFlag.sideCard => c.sideCard,
          },
        )
        .length;
    return _tri(on, of.length);
  }

  static bool? _tri(int on, int total) =>
      on == 0 ? false : (on == total ? true : null);

  /// Стеллажи ячеек выборки (без ячеек без стеллажа), без повторов.
  Set<String> rackIds(Iterable<CellSetup> list) => {
    for (final c in list)
      if (c.rackId != null) c.rackId!,
  };

  /// Сколько чего напечатает выборка: этикеток на большую, на малую балку и карточек. Карточка —
  /// на каждый стеллаж, где в выборке есть ячейка с галочкой «на карточке»; в карточке — все
  /// такие ячейки стеллажа. Как `sideCards` бэкенда.
  ({int large, int small, int cards}) printCounts(List<CellSetup> list) {
    final small = list.where((c) => c.labelSmall).length;
    return (
      large: list.length - small,
      small: small,
      cards: rackIds(list.where((c) => c.sideCard)).length,
    );
  }

  static int _stickOrder(CellSetup a, CellSetup b) {
    final ra = a.rackCode, rb = b.rackCode;
    if (ra != rb) {
      if (ra == null) return 1;
      if (rb == null) return -1;
      final r = naturalCompare(ra, rb);
      if (r != 0) return r;
    }
    final p = (a.position ?? 0).compareTo(b.position ?? 0);
    if (p != 0) return p;
    final t = (b.tier ?? 0).compareTo(a.tier ?? 0);
    return t != 0 ? t : naturalCompare(a.address, b.address);
  }
}

/// Натуральный порядок: числа сравниваются по значению (`B-1-2-9` раньше `B-1-2-10`).
int naturalCompare(String a, String b) {
  final re = RegExp(r'\d+|\D+');
  final pa = re.allMatches(a).map((m) => m[0]!).toList();
  final pb = re.allMatches(b).map((m) => m[0]!).toList();
  for (var i = 0; i < pa.length && i < pb.length; i++) {
    final na = int.tryParse(pa[i]), nb = int.tryParse(pb[i]);
    final c = na != null && nb != null
        ? na.compareTo(nb)
        : pa[i].compareTo(pb[i]);
    if (c != 0) return c;
  }
  return pa.length.compareTo(pb.length);
}
